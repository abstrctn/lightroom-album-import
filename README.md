# lightroom-album-import

The `lightroom-album-import` GitHub Action downloads images from a public Lightroom album, along with associated Exif metadata.

## When to use

This action can be used to automate exporting Lightroom images to another destination as part of a workflow, letting you use one or more albums as the source of truth for a portfolio, website or any content management system with an API. It supports exporting XMP sidecar files to allow for incremental metadata updates, including when storing images in external storage or [Git Large File Storage](https://git-lfs.com/).

See also:
- [Including Exif metadata within or alongside images](#exif-metadata)
- [Optimizing image downloads on subsequent executions](#image-download-optimization)
- [Create markdown file for an impored album](https://github.com/abstrctn/lightroom-album-import/blob/main/usage/generate-markdown.sh)

## Terms of use

This action hits publicly-accessible API endpoints hosted by Adobe for shared albums. While it attempts to avoid unnecessary bandwidth use by caching image content and metadata, be sure to use this respectfully. Some basic guidelines to keep this tool unobtrusive:
* Run this action only in response to known changes to an album. For example, trigger the action in response to a new Issue to "Update adobe.ly/abc123", as opposed to on a cron or schedule.
* Leave the `optimize_image_downloads` setting enabled, unless trying to force a manual update.
* Leave the User-Agent string identifying this action in place.

## Usage

```yml
  - name: Import Album
    id: import-album
    uses: abstrctn/lightroom-album-import

  # Do something with the images, e.g. make a Pull Request
```

### Album requirements

This action doesn't currently authenticate to your Adobe account. While a native Adobe integration would be a welcome improvement to this action, to keep things simple at the moment it relies on unauthenticated access to the public APIs used by javascript on the publicly shared album pages. To use this action, you must shared your album publicly. Adobe provides instructions for this [here](https://helpx.adobe.com/lightroom-cc/using/save-share-photos.html). You can disable public access after running this action if you wish.

Additionally, to add all available Exif metadata to images, you must enable the "Show metadata" and "Show location" toggles in the Share & Invite Settings tab.

Albums up to 500 photos are supported, as limited by the [Lightroom API's limit](https://developer.adobe.com/lightroom/lightroom-api-docs/api/#tag/Albums/operation/listAssetsOfAlbum) of 500 images per response, but support for pagination would be a welcome contribution.

### Action inputs

Only `album_url` is required.

| Name | Description | Default |
| --- | --- | --- |
| `album_url` | The shareable link to an album (startinh with `adobe.ly`, or the unfurled `lightroom.adobe.com/shares/`) | (required) |
| `default_copyright` | Default value to populate rights-related image metadata fields with, if the copyright field isn't set in Lightroom | `null` |
| `download_directory` | Relative path of the destination for downlaoded images (the string `$album_name` will be replaced with the album's name) | `root` |
| `rendition_type` | Which image rendition / size to download (2048, 1080, 640, thumbnail2x). Decrease from the default to save on space. The larger `2560` and `fullsize` aren't available when using the unauthenticated Lightroom API. | `2048` |
| `add_exif_metadata` | Embed all available exif metadata into the downloaded images (which are without most metadata by default) | `true` |
| `optimize_image_downloads` | Skip redownloading any image that already exists on the filesystem, if the image content hasn't changed | `true` |
| `hide_stacked_assets` | Don't include images that are part of, but not at the top of, a stack | `true` |
| `save_xmp` | Save or update XMP sidecar files with image metadata | `false` |
| `save_json` | Save or update the JSON representation of every lightroom image asset | `false` |

### Action outputs

Variables that can be used by later workflow steps.

* `album_id` - The unique album asset id from Adobe's API
* `album_name` - The album name
* `album_sort_order` - The album's sort order (`captureDate`, `importTimestamp`, `fileName`, `rating`, `userUpdated` + `Asc` or `Desc`, e.g., `captureDateAsc`.)
* `sorted_image_ids` - Space-delimited list of image asset IDs
* `sorted_image_paths` - Space-delimited list of relative image filepaths

```yml
  - name: Import Album
    id: import-album
    uses: abstrctn/lightroom-album-import
  - name: Check outputs
    run: |
      echo "Album name: ${{ steps.import-album.outputs.album_name }}"
```

## Image download optimization

To avoid redownloading images every time the action runs, leave `optimize_image_downloads` set to `true`. This makes use of two timestamps provided in each image asset's JSON metadata. (This is somewhat assumed from behavior.)
* `.asset.payload.userUpdated` - The last time the image content has changed.
* `.asset.payload.develop.userUpdated` - The last time any user-editable metadata has changed.

These timestamps are stored in the `xmp:ModifyDate` and `xmp:MetadataDate`, exif tags, respectively.

When `optimize_image_downloads` is enabled, the action will check for the presence of an `xmp:ModifyDate` tag first at the filepath for the image, and then at the filepath of the image's potential xmp sidecar file. If a tag value is found and it matches the incoming value, the image will not be redownloaded.

Similarly, if the `xmp:MetadataDate` value within an XMP sidecar file matches the incoming value, the sidecar file will not be updated.

### When using Git LFS or storing images outside of Git

If you store images by saving them in external storage, or by using Git LFS, then the above timestamps won't be available on the image file. In both cases, you can enable the creation of [XMP sidecar files](https://en.wikipedia.org/wiki/Sidecar_file) using the `save_xmp` setting. These will be saved at the same filepath as downloaded images, but with the `.xmp` extension.

These files will contain all of the populated exif tag values, and will be used to determine whether or not to download images.

### Prevent updating image files stored in Git
when only the metadata changes

When storing images in Git or Git LFS, any change to the image binary will force a new copy of the image into your Git history, even if the only change is an Exif tag value. You may want to avoid this for storage or bandwidth reasons, especially if you're storing metadata values in a separate sidecar file.

This can be accomplished by stripping out select exif tags after this action runs. The "Strip metadata" step below unsets all tags that can be changed from within the Lightroom UI, which should prevent new image versions unless the visual content of the image changes.

```yml
  - name: Import Album
    id: import-album
    uses: abstrctn/lightroom-album-import
    with:
      save_xmp: 'true'

  # Do something with the images

  - name: Strip metadata
    run: |
      # Install exiftool
      sudo apt-get -qq install -y libimage-exiftool-perl

      for image in ${{ steps.import_album_images.outputs.sorted_image_paths }}; do
        exiftool \
          -xmp-dc:Rights= \
          -xmp-dc:Title= \
          -xmp-dc:Description= \
          -xmp-dc:Creator= \
          -xmp-photoshop:Credit= \
          -xmp:MetadataDate= \
          -xmp:ModifyDate= \
          -xmp:Label= \
          -iptc:CopyrightNotice= \
          -Location= \
          -City= \
          -State= \
          -Country= \
          -CopyrightNotice= \
          -XMPToolkit= \
          -overwrite_original

  # Check images into git or git lfs
```

This isn't built into the step on the assumption that you may want to use the images with fully populated exif tags elsewhere in the workflow, e.g. to generate mulitple renditions of each image.

## Extending functionality

By setting `save_json` to `true`, you can have access to the full set of Adobe-provided metadata for every image in the album. This can be useful when:
* Requiring access to any JSON values not mapped to Exif tags within the action
* Accessing rating, keyword or region data for an image that is applied from Adobe's AI tools

Similar to XMP sidecar files, Adobe's resource data is saved with the same filename as an image, but with the `.json` extension.

## Exif metadata

Images downloaded from shared albums lack most of the metadata fields included when doing an image export from the Lightroom desktop or mobile apps (even when the shared album is configured to "Show metadata.") When viewing a shared album in a browser, metadata is made available as a JSON response which is then rendered alongside the images.

This action reapplies that metadata into the image's Exif tags. To do so, the structure of the JSON needs to be mapped to the Exif metadata tag names and data types. This is done by:
1. Extracting the available JSON values into bash variables
2. Translating those values to the human readable equivalent values that `exiftool` expects as input
3. Using the `exiftool` cli to assign those values to specific Exif tags

As an example of the translation needed, Adobe's JSON data for an image's Flash Mode tag might have the value `compulsory flash suppression`, which is a value listed in the [exif specification for that field](https://github.com/adobe/xmp-docs/blob/e2573ad7e7959e657b1aed704546e19319cb4f5d/XMPNamespaces/XMPDataTypes/Flash.md?plain=1#L13). However, exiftool's `PrintConv`, or human-readable version of that value, which is used for setting and getting values, is instead called "off". The `metadata-translation.csv` file maps the former to the latter. ([Read more in the exiftool docs.](https://exiftool.org/under.html#conversions))
