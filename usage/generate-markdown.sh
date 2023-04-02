#!/bin/bash

# Generate or update a markdown file for a Lightroom album, for use in a Jekyll-like website.
# Relies on the given conventions for the album's metadata:
# - Artist / act name is stored in the "Title" field of every image
#   - The first artist listed in an image (by sort order) is considered the headliner,
#     all others supporting acts.
# - Venue is stored in the "Location" field (only 1 venue supported).
# - The first image is used as the featured image.
# - Content after the frontmatter is used as an article body.
#
# Example output:
# 
# ---
# title: Palace
# support:
# - Liam Benzvi
# - Loose Buttons
# date: 2022-05-05 00:00:00
# day: 2022-05-05
# venue: Webster Hall
# slug: palace-webster-hall-may-5th-2022
# featured_image: /images/live/2022-05-05-palace/DSC08402_dae817.jpg
# images:
# - images/live/2022-05-05-palace/DSC08402_dae817.jpg
# - images/live/2022-05-05-palace/DSC08477_5f95f8.jpg
# - images/live/2022-05-05-palace/DSC08499_b87b0f.jpg
# - images/live/2022-05-05-palace/DSC08572_f200e5.jpg
# - images/live/2022-05-05-palace/DSC08594_bb7af4.jpg
# - images/live/2022-05-05-palace/DSC08620_9b1a3a.jpg
# - images/live/2022-05-05-palace/DSC08206_1eaf35.jpg
# - images/live/2022-05-05-palace/DSC08297_3eabd2.jpg
# - images/live/2022-05-05-palace/DSC07994_91e3fc.jpg
# - images/live/2022-05-05-palace/DSC08105_ae9e05.jpg
# - images/live/2022-05-05-palace/DSC08008_f9b3e5.jpg
# - images/live/2022-05-05-palace/DSC08101_1c67b5.jpg
# - images/live/2022-05-05-palace/DSC08070_7a228c.jpg
# ---

shopt -s nocasematch

# Assumes that imported albums follow a standard naming convention:
# yyyy-mm-dd-act-name

album_name=$1
slug=${album_name:11}
date=${album_name:0:10}
img_dir=images/live/$album_name
images=($SORTED_IMAGE_PATHS)

# Change image dir ownership to current user (files added by GitHub actions default to root)
sudo chown -R $USER $img_dir

# Extract the headlining act from the album slug
act_name=$(echo $album_name | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//g; s/-/ /g')
title=$(perl -e '$_="'"$act_name"'"; s/\b(\w)/\U$1/g; print;')

# Featured image is the first image in the album
featured_image=${images[0]}

# Assue that each image's title depicts the act name.
# Any acts that don't match the album's name are considered supporting.
# Check the `.xmp` sidecars for metadata, as .jpgs aren't checked into the repo.
support=""
while IFS=$'\n' read -r act; do
  if [[ ! -z "$act" ]] && [[ ! "$act_name" =~ "$act" ]]; then
    support="$support"$'\n'"- $act"
  fi
done < <(exiftool -j -Title $img_dir/*.xmp | jq -j '[.[] | .Title] | del(..|nulls) | unique | join("\n") + "\n"')

# Prepend the support array with a yaml field if supporting acts were found
if [ ! -z "${support}" ]; then
  support=$'\n'"support:$support"
fi

# Get the first venue stored in the Location field, and convert it to a slug
venue=$(exiftool -j -Location $img_dir/*.xmp | jq -j '[.[] | .Location] | del(..|nulls) | first')
venue_slug=$(echo $venue | sed 's/ /-/g' | tr -d "'" | tr '[:upper:]' '[:lower:]' | sed 's/^the-//g')

# Construct a date-slug
# 2022-01-01 > january-1st-2022
year=${date:0:4}
month=${date:5:2}
day=${date:8:2}

# Add leading zeroes to month and day
month=$((10#$month))
day=$((10#$day))

monthnames=(invalid january february march april may june july august september october november december)
month=${monthnames[$month]}
ordinals=(invalid st nd rd th th th th th th th th th th th th th th th th th st nd rd th th th th th th th st)
ordinal=${ordinals[$day]}

# Construct slugs based on english month names and ordinals
# e.g., january-1st-2023
date_slug=${month}-$((day))${ordinal}-${year}
url_slug=${slug}-${venue_slug}-${date_slug}

# Bootstrap concert file, preserving all frontmatter lines until `images` or
# `featured_image` and the post body if they exist.
live=_live/$album_name.md
live_body=

if [ -f $live ]; then
  echo "Upating existing file at $live"
  # Find first line we don't want to preserve (anything involving images)
  preserve_until=$(grep -n -E '(images|featured_image):' $live | head -1 | cut -d: -f1)
  echo preserve_until=$preserve_until

  # Rebuild entire file if we can't find an image
  if [ -z "$preserve_until" ]; then preserve_until=1; fi

  # Preserve post body (anything after the end of frontmatter, "---")
  if [ "$(grep -n '\-\-\-' $live | wc -l)" -ge 2 ]; then
    preserve_after=$(grep -n '\-\-\-' $live | head -2 | tail -1 | cut -d: -f1)
    echo preserve_after=$preserve_after
    live_body="$(tail -n +$(($preserve_after+1)) $live)"
  fi

  # Truncate at $preserve_until
  temp=$(mktemp)
  head -n$((preserve_until-1)) $live > $temp && mv $temp $live
fi

if [ ! -s $live ]; then
  echo "Writing new file at $live"
  echo "---
title: ${title}${support}
date: $date 00:00:00
day: $date
venue: $venue
slug: $slug-$venue_slug-$date_slug" > $live
fi

echo "Adding images to $live"
echo "featured_image: /$featured_image" >> $live
echo "images:" >> $live
for image in "${images[@]}"; do
  echo "- $image" >> $live
done
echo "---" >> $live

echo "Adding body to $live"
if [ ! -z "$live_body" ]; then
  echo "$live_body" >> $live
fi

echo "album_name=$album_name" >> $GITHUB_OUTPUT
echo "slug=$slug" >> $GITHUB_OUTPUT
echo "url_slug=$url_slug" >> $GITHUB_OUTPUT
