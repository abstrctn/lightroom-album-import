#!/bin/bash
shopt -s nocasematch

USER_AGENT="lightroom-album-import (https://github.com/abstrctn/lightroom-album-import)"

album_url=$(echo ${INPUT_ALBUM_URL} | grep -E -o '(adobe\.ly\/[A-Za-z0-9]+)|(lightroom\.adobe\.com\/shares\/[a-z0-9]+)')
if [ -z "$album_url" ]; then
  echo "::error album_url requried"
  exit 1
fi

INPUT_ADD_EXIF_METADATA=${INPUT_ADD_EXIF_METADATA:-true}
INPUT_OPTIMIZE_IMAGE_DOWNLOADS=${INPUT_OPTIMIZE_IMAGE_DOWNLOADS:-true}
INPUT_RENDITION_TYPE=${INPUT_RENDITION_TYPE:-2048}
INPUT_HIDE_STACKED_ASSETS=${INPUT_HIDE_STACKED_ASSETS:-true}
INPUT_SAVE_XMP=${INPUT_SAVE_XMP:-false}
INPUT_SAVE_JSON=${INPUT_SAVE_JSON:-false}
INPUT_DOWNLOAD_DIRECTORY=${INPUT_DOWNLOAD_DIRECTORY:-./}

echo "::debug::INPUT_DOWNLOAD_DIRECTORY=$INPUT_DOWNLOAD_DIRECTORY"
echo "::debug::INPUT_ADD_EXIF_METADATA=$INPUT_ADD_EXIF_METADATA"
echo "::debug::INPUT_OPTIMIZE_IMAGE_DOWNLOADS=$INPUT_OPTIMIZE_IMAGE_DOWNLOADS"
echo "::debug::INPUT_RENDITION_TYPE=$INPUT_RENDITION_TYPE"
echo "::debug::INPUT_SAVE_XMP=$INPUT_SAVE_XMP"
echo "::debug::INPUT_SAVE_JSON=$INPUT_SAVE_JSON"
echo "::debug::album_url=$album_url"

if [[ ! "$INPUT_RENDITION_TYPE" =~ ^(2048|1080|640|thumbnail2x)$ ]]; then
  echo "rendition_type must be one of: 2048, 1080, 640, thumbnail2x (was '$INPUT_RENDITION_TYPE')"
  exit 1
fi

album_html=$(mktemp)
curl -s -A "$USER_AGENT" -s -L $album_url -o $album_html
if [ $? -ne 0 ]; then
  echo "::error Accessing $album_url failed."
  exit 1
fi

# Extract album metadata from the window.SharesConfig variable
line_start=$(grep -Fn 'window.SharesConfig =' $album_html | grep -Eo '^[0-9]+')
# Standardize quoting to be valid JSON
page_metadata="{$(
  cat $album_html | tail -n +$((line_start+1)) | head -2 \
    | sed 's/spaceAttributes/"spaceAttributes"/g; s/albumAttributes/"albumAttributes"/g'
)}"
rm $album_html

IFS=$'\t' read -r share_id album_id url_prefix album_name album_sort_order < <(echo $page_metadata | jq -j '[
  .spaceAttributes.id,
  .albumAttributes.id,
  .albumAttributes.links.self.href,
  .albumAttributes.payload.name,
  .albumAttributes.payload.assetSortOrder
] | join("\t")')
echo "::debug::album_name=$album_name"
echo "::debug::album_id=$album_id"

# Accepts parameters defined at https://developer.adobe.com/lightroom/lightroom-api-docs/api/#tag/Albums/operation/listAssetsOfAlbum
json_url="https://lightroom.adobe.com/v2/$url_prefix/assets?embed=asset%3Buser&limit=500&order_after=-&exclude=incomplete&subtype=image&hide_stacked_assets=$INPUT_HIDE_STACKED_ASSETS"
json="$(curl -A "$USER_AGENT" -s "$json_url" | tail -1)"
if [ $? -ne 0 ]; then
  echo "::error Accessing $json_url failed."
  exit 1
fi

# Construct a file containing the metadata about each image, base64-encoded,
# one resource per row
resources=$(mktemp)
echo "$json" | jq -j '[.resources[] | @base64] | join("\n") + "\n"' > $resources

# Allow substitution of `$album_name` in download directory
img_dir=${INPUT_DOWNLOAD_DIRECTORY}
img_dir=${img_dir/\$album_name/$album_name}
mkdir -p "$img_dir"

sorted_image_ids=()
sorted_image_paths=()

function adobe-to-exiftool {
  field=$1
  adobe_value=$2

  cat /metadata-translation.csv | grep "^$field,$adobe_value," | cut -d, -f3
}

# datetime_updated: When anything about the image has changed
# datetime_image_updated: When the image content has changed, fall back to
#   the datetime_updated if the image content has never been edited
while IFS=, read -r xmp; do
  # Extract all metadata fields Lightroom passes along in the shared album JSON.
  # * Convert rational values from a numerator/denominator array to a decimal value.
  # * City/State/Country can exist as both human-specified inputs, or values derived from
  #   GPS data. Override the latter with the former to allow for edits.

  # This list attempts to be comprehensive, but currently omits xmp.dc.creator and xmp.dc.subject,
  # which are array / sequence data types.

  # Use an uncommon codepoint 037 (unit separator) as delimiter to allow for empty values:
  # https://stackoverflow.com/questions/66480618/bash-how-to-read-tab-separated-line-with-empty-colums-from-file-into-array
  IFS=$'\037' read -r id download_2048 datetime_image_updated datetime_updated filename sha aperture_value max_aperture_value shutter_speed_value f_number exposure_time focal_length brightness_value exposure_bias_value approximate_focus_distance iso focal_length_in_35 flash_red_eye_mode flash_fired flash_return flash_mode flash_function light_source metering_mode exposure_program user_comment make model lens serial_number location date_created city state country rights title description creatortool label xmprights_marked xmprights_usageterms xmprights_webstatement longitude latitude < <(echo $xmp | base64 -d | jq -j '[
    .id,
    .asset.links["/rels/rendition_type/2048"].href,
    .asset.payload.develop.userUpdated // .asset.payload.userUpdated,
    .asset.payload.userUpdated,
    .asset.payload.importSource.fileName,
    .asset.payload.importSource.sha256,
    if .asset.payload.xmp.exif.ApertureValue then (.asset.payload.xmp.exif.ApertureValue[0] / .asset.payload.xmp.exif.ApertureValue[1] | tostring) else "" end,
    if .asset.payload.xmp.exif.MaxApertureValue then (.asset.payload.xmp.exif.MaxApertureValue[0] / .asset.payload.xmp.exif.MaxApertureValue[1] | tostring) else "" end,
    if .asset.payload.xmp.exif.ShutterSpeedValue then (.asset.payload.xmp.exif.ShutterSpeedValue[0] / .asset.payload.xmp.exif.ShutterSpeedValue[1] | tostring) else "" end,
    if .asset.payload.xmp.exif.FNumber then (.asset.payload.xmp.exif.FNumber[0] / .asset.payload.xmp.exif.FNumber[1] | tostring) else "" end,
    if .asset.payload.xmp.exif.ExposureTime then (.asset.payload.xmp.exif.ExposureTime[0] | tostring) + "/" + (.asset.payload.xmp.exif.ExposureTime[1] | tostring) else "" end,
    if .asset.payload.xmp.exif.FocalLength then (.asset.payload.xmp.exif.FocalLength[0] | tostring) + "/" + (.asset.payload.xmp.exif.FocalLength[1] | tostring) else "" end,
    if .asset.payload.xmp.exif.BrightnessValue then (.asset.payload.xmp.exif.BrightnessValue[0] | tostring) + "/" + (.asset.payload.xmp.exif.BrightnessValue[1] | tostring) else "" end,
    if .asset.payload.xmp.exif.ExposureBiasValue then (.asset.payload.xmp.exif.ExposureBiasValue[0] | tostring) + "/" + (.asset.payload.xmp.exif.ExposureBiasValue[1] | tostring) else "" end,
    if .asset.payload.xmp.aux.ApproximateFocusDistance then (.asset.payload.xmp.aux.ApproximateFocusDistance[0] | tostring) + "/" + (.asset.payload.xmp.aux.ApproximateFocusDistance[1] | tostring) else "" end,
    .asset.payload.xmp.exif.ISOSpeedRatings,
    .asset.payload.xmp.exif.FocalLengthIn35mmFilm,
    .asset.payload.xmp.exif.FlashRedEyeMode,
    .asset.payload.xmp.exif.FlashFired,
    .asset.payload.xmp.exif.FlashReturn,
    .asset.payload.xmp.exif.FlashMode,
    .asset.payload.xmp.exif.FlashFunction,
    .asset.payload.xmp.exif.LightSource,
    .asset.payload.xmp.exif.MeteringMode,
    .asset.payload.xmp.exif.ExposureProgram,
    .asset.payload.xmp.exif.UserComment,
    .asset.payload.xmp.tiff.Make,
    .asset.payload.xmp.tiff.Model,
    .asset.payload.xmp.aux.Lens,
    .asset.payload.xmp.aux.SerialNumber,
    .asset.payload.xmp.iptcCore.Location,
    .asset.payload.xmp.photoshop.DateCreated,
    .asset.payload.xmp.photoshop.City // .asset.payload.location.city,
    .asset.payload.xmp.photoshop.State // .asset.payload.location.state,
    .asset.payload.xmp.photoshop.Country // .asset.payload.location.country,
    .asset.payload.xmp.dc.rights,
    .asset.payload.xmp.dc.title,
    .asset.payload.xmp.dc.description,
    .asset.payload.xmp.xmp.CreatorTool,
    .asset.payload.xmp.xmp.Label,
    .asset.payload.xmp.xmpRights.Marked,
    .asset.payload.xmp.xmpRights.UsageTerms,
    .asset.payload.xmp.xmpRights.WebStatement,
    .asset.payload.location.longitude,
    .asset.payload.location.latitude
  ] | join("\t")' | tr '\t' '\037')

  orig_name=$(echo $filename | sed 's/\..*//g')

  # Path to save the image to. Include a partial sha to allow for images with the same name.
  image_path=$img_dir/${orig_name}_${sha:0:6}.jpg
  xmp_path="${image_path/%jpg/xmp}"
  json_path="${image_path/%jpg/json}"

  sorted_image_ids+=($id)
  sorted_image_paths+=($image_path)

  # Optionally save resource JSON
  if [[ "$INPUT_SAVE_JSON" == "true" ]]; then
    echo $xmp | base64 -d | jq > "$json_path"
  fi

  # Convert human readable values into exiftool's PrintConv values
  # 
  # There are a number of named values for which exiftool uses names other than
  # those defined in the spec. (e.g., it calls ExposureMode's "normal program" mode "Program AE").
  # Since Adobe seems to use the standard values, this normalizes those changes.

  if [ ! -z "$flash_mode" ]; then
    flash_mode=$(adobe-to-exiftool EXIF:FlashMode "$flash_mode")
  fi

  if [ ! -z "$flash_return" ]; then
    flash_return=$(adobe-to-exiftool EXIF:FlashReturn "$flash_return")
  fi

  if [ ! -z "$metering_mode" ]; then
    metering_mode=$(adobe-to-exiftool EXIF:MeteringMode "$metering_mode")
  fi

  if [ ! -z "$exposure_program" ]; then
    exposure_program=$(adobe-to-exiftool EXIF:ExposureProgram "$exposure_program")
  fi

  # Handle APEX values. Exiftool expects fstop equivalent (human readable) values
  # as inputs and converts them back to APEX internally.
  # TODO: Unset ApertureValue, MaxApertureValue for invalid values, .e.g. for lenses
  # with a aperture wider than 1.0.

  if [ ! -z "$aperture_value" ]; then
    aperture_value=$(echo "scale=16; e($aperture_value*l(sqrt(2)))" | bc -l)
  fi

  if [ ! -z "$max_aperture_value" ]; then
    max_aperture_value=$(echo "scale=16; e($max_aperture_value*l(sqrt(2)))" | bc -l)
  fi

  if [ ! -z "$shutter_speed_value" ]; then
    shutter_speed_value=$(echo "scale=16; 1/e($shutter_speed_value*l(2))" | bc -l)
  fi

  # Default the author specified in .asset.payload.xmp.dc.rights to $INPUT_DEFAULT_COPYRIGHT.
  if [ -z "$rights" ]; then
    rights=$INPUT_DEFAULT_COPYRIGHT
  fi
  
  # Decide whether to download image.
  # Skip if the image's `.asset.payload.develop.userUpdated` property is equal to
  # the xmp:ModifyDate metadata on either:
  # * An existing image at the download filepath
  # * A sidecar .xmp file at the download filepath (replace .jpg with .xmp)
  image_last_modified=""
  metadata_last_modified=""
  if [ -z "$image_last_modified" ] && [ -f "$image_path" ]; then
    image_last_modified="$(exiftool -d "%Y-%m-%dT%H:%M:%S%fZ" -s -s -s -xmp:ModifyDate "$image_path")"
    metadata_last_modified="$(exiftool -d "%Y-%m-%dT%H:%M:%S%fZ" -s -s -s -xmp:MetadataDate "$image_path")"
  fi
  if [ -z "$image_last_modified" ] && [ -f "$xmp_path" ]; then
    image_last_modified="$(exiftool -d "%Y-%m-%dT%H:%M:%S%fZ" -s -s -s -xmp:ModifyDate "$xmp_path")"
    metadata_last_modified="$(exiftool -d "%Y-%m-%dT%H:%M:%S%fZ" -s -s -s -xmp:MetadataDate "$xmp_path")"
  fi

  # Download image if
  # * "OPTIMIZE_IMAGE_DOWNLOADS" is set to anything but "true"
  # * An xmp:ModifyDate wasn't found in the existing image file path or xmp sidecar
  # * An xmp:ModifyDate was found, and it's different from the
  #   `.asset.payload.develop.userUpdated` field in adobe's metadata
  download_image=
  if [[ "$INPUT_OPTIMIZE_IMAGE_DOWNLOADS" != "true" ]] || \
     [[ ! -f "$image_path" ]] || \
     [[ -z "$image_last_modified" ]] || \
     [[ "$datetime_image_updated" != "$image_last_modified" ]]; then
    download_image=true
  fi
  update_metadata=
  if [[ -z "$metadata_last_modified" ]] || \
     [[ "$datetime_updated" != "$metadata_last_modified" ]]; then
    update_metadata=true
  fi

  if [[ "$download_image" == "true" ]]; then
    echo "::debug::$datetime_image_updated != $image_last_modified"
    image_url=https://lightroom.adobe.com/v2c/spaces/$share_id/$download_2048
    echo "::debug::Downloading $image_url to $image_path..."
    curl -A "$USER_AGENT" -s $image_url -o "$image_path"
    if [ $? -ne 0 ]; then
      echo "::error Downloading failed."
      exit 1
    fi
  else
    echo "::debug::Skip downloading $image_path, not updated"
  fi

  if [[ "$INPUT_ADD_EXIF_METADATA" == "true" ]]; then
    # Map JSON metadata from Adobe to relevant EXIF tags
    # Also populate XMP:ModifyDate and XMP:MetadataDate with userUpdated fields from Adobe,
    # as well as EXIF:ImageUniqueId from the image's asset id in lightroom.
    # Unset the XMPToolkit tag to avoid changing the binary if the exiftool version changes
    files_to_update=()
    if [ "$download_image" == "true" ]; then files_to_update+=("$image_path"); fi
    if [ "$INPUT_SAVE_XMP" == "true" ] && [ "$update_metadata" == "true" ]; then files_to_update+=("$xmp_path"); fi

    # Set exif tags on image and/or xmp sidecar files.
    # If sidecar is generated from scratch, base it on the image when available
    # to include metadata like image width/height.
    for file in ${files_to_update[@]}; do
      echo "::debug::Applying exif metadata to $file..."
      exiftool \
        $(if [ "$file" == "$xmp_path" ] && [ ! -f "$xmp_path" ]; then echo "-tagsFromFile $image_path"; fi) \
        "-EXIF:ImageUniqueId=$id" \
        "-EXIF:ApertureValue=$aperture_value" \
        "-EXIF:MaxApertureValue=$max_aperture_value" \
        "-EXIF:ShutterSpeedValue=$shutter_speed_value" \
        "-EXIF:FNumber=$f_number" \
        "-EXIF:ExposureTime=$exposure_time" \
        "-EXIF:ISO=$iso" \
        "-EXIF:FocalLength=$focal_length" \
        "-EXIF:FocalLengthIn35mmFormat=$focal_length_in_35" \
        "-EXIF:Make=$make" \
        "-EXIF:Model=$model" \
        "-EXIF:LensModel=$lens" \
        "-EXIF:BrightnessValue=$brightness_value" \
        "-EXIF:ExposureCompensation=$exposure_bias_value" \
        "-EXIF:UserComment=$user_comment" \
        "-FlashMode=$flash_mode" \
        "-FlashFired=$flash_fired" \
        "-FlashReturn=$flash_return" \
        "-FlashFunction=$flash_function" \
        "-LightSource=$light_source" \
        "-MeteringMode=$metering_mode" \
        "-ExposureProgram=$exposure_program" \
        "-Location=$location" \
        "-City=$city" \
        "-State=$state" \
        "-Country=$country" \
        "-iptc:CopyrightNotice=$rights" \
        "-GPSLatitude*=$latitude" \
        "-GPSLongitude*=$longitude" \
        "-xmp-aux:SerialNumber=$serial_number" \
        "-xmp-aux:ApproximateFocusDistance=$approximate_focus_distance" \
        "-xmp-dc:Rights=$rights" \
        "-xmp-dc:Title=$title" \
        "-xmp-dc:Description=$description" \
        -xmp-dc:Creator= "-xmp-dc:Creator=$rights" \
        "-xmp-photoshop:DateCreated=$date_created" \
        "-xmp-photoshop:Credit=$rights" \
        "-xmp:CreatorTool=$creatortool" \
        "-xmp:Label=$label" \
        "-xmp-xmpRights:Marked=$xmprights_marked" \
        "-xmp-xmpRights:UsageTerms=$xmprights_usageterms" \
        "-xmp-xmpRights:WebStatement=$xmprights_webstatement" \
        "-xmp:MetadataDate=$datetime_updated" \
        "-xmp:ModifyDate=$datetime_image_updated" \
        "-XMPToolkit=" \
        -overwrite_original \
        "$file"
    done
  fi
done < $resources
rm $resources

echo "album_id=$album_id" >> $GITHUB_OUTPUT
echo "album_name=$album_name" >> $GITHUB_OUTPUT
echo "album_sort_order=$album_sort_order" >> $GITHUB_OUTPUT
echo "sorted_image_ids=${sorted_image_ids[@]}" >> $GITHUB_OUTPUT
echo "sorted_image_paths=${sorted_image_paths[@]}" >> $GITHUB_OUTPUT