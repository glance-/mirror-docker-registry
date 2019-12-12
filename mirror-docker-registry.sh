#!/bin/bash
#
# Mirror one docker registry to another
#

set -e

function tag_to_image_id
{
	local uri=$1
    local image=$2
    local tag=$3

    image_id=$(curl -s -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "${uri}/v2/${image}/manifests/${tag}" | jq -r '.config.digest')

    echo "$image_id"
    return 0
}

function copy_docker_image
{
	local source_uri=$1
	# Tag is going to be the same in both ends
	local image=$2
	local tag=$3
	local dest_uri=$4

    local manifest
    manifest=$(curl -s -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "${source_uri}/v2/${image}/manifests/${tag}")

	jq -j '.layers[], .config | [.mediaType, " ", .size, " ", .digest, "\n"] | .[]' <<< "${manifest}" | while read -r mediaType size digest ; do
	echo -n "Layer: ${digest:7:17} $(printf "%20s" "$size") "
		if curl -s -o /dev/null --fail -I "${dest_uri}/v2/${image}/blobs/$digest" ; then
			echo "Exists"
			# Blob already exists
			continue
		fi
		echo -n "Copying "
		# Get upload url
		upload_url=$(curl -s --fail -D - -o /dev/null -X POST "${dest_uri}/v2/${image}/blobs/uploads/" | grep ^Location: | tr -d '\r')
		upload_url=${upload_url/Location: /}
		# Upload blob
		curl -s --fail "${source_uri}/v2/${image}/blobs/$digest" | curl -s -N --fail -L -X PUT -H "Content-Type: $mediaType" -H "Content-Lenght: $size" --data-binary @- "$upload_url&digest=$digest"
		echo "done"
	done

	echo -n "Uploading manifest "
	curl -s --fail -X PUT --data-raw "${manifest}" -H "Content-Type: application/vnd.docker.distribution.manifest.v2+json" "${dest_uri}/v2/${image}/manifests/${tag}" 
}

if [ "$#" != 2 ] ; then
	echo "Usage: $0 SOURCE DEST"
	echo
	echo "Ex: $0 hub.docker.com localhost"
	exit 1
fi

SOURCE=$1
DEST=$2

if [[ "$SOURCE" = localhost* ]] ; then
	SOURCE_URI="http://${SOURCE}"
elif [[ "$SOURCE" = http* ]] ; then
	SOURCE_URI=$SOURCE
	SOURCE=${SOURCE/http*:\/\//}
else
	SOURCE_URI="https://${SOURCE}"
fi
if [[ "$DEST" = localhost* ]] ; then
	DEST_URI="http://${DEST}"
elif [[ "$DEST" = http* ]] ; then
	DEST_URI=$DEST
	DEST=${DEST/http*:\/\//}
else
	DEST_URI="https://${DEST}"
fi

UPDATES_DONE=false
for repo in $(curl -s --fail "${SOURCE_URI}/v2/_catalog?n=100000" | jq -r ".repositories[]"); do
    LOCAL_TAGS=()
    for tag in $(curl -s --fail "${SOURCE_URI}/v2/${repo}/tags/list" | jq -r ".tags[]"); do
        SOURCE_ID=$(tag_to_image_id "${SOURCE_URI}" "${repo}" "${tag}")
        DEST_ID=$(tag_to_image_id "${DEST_URI}" "${repo}" "${tag}")
		echo -n "$(printf "%-80s" "${SOURCE}/${repo}:${tag}") (${SOURCE_ID:7:17})"
        if [ "$SOURCE_ID" != "$DEST_ID" ] ; then
            echo -n " -> ${DEST}"
            if [ "$DEST_ID" = "null" ] ; then
                echo " New"
            else
				UPDATES_DONE=true
                echo " Update (was ${DEST_ID:7:17})"
            fi
			# Bounce via local dockerd
            #docker pull "${SOURCE}/${repo}:${tag}" && docker tag "${SOURCE}/${repo}:${tag}" "${DEST}/${repo}:${tag}" && docker push "${DEST}/${repo}:${tag}"
            #LOCAL_TAGS+=("${DEST}/${repo}:${tag}" "${SOURCE}/${repo}:${tag}")
			# Just copy the data between the registries, not involving dockerd.
			copy_docker_image "${SOURCE_URI}" "${repo}" "${tag}" "${DEST_URI}"
			echo "Done!"
        else
            echo " already in sync (${DEST_ID:7:17})"
        fi
   done
   if [ "${#LOCAL_TAGS[@]}" -gt 0 ] ; then
       docker rmi "${LOCAL_TAGS[@]}"
   fi
done

DELETES_DONE=false
for repo in $(curl -s --fail "${DEST_URI}/v2/_catalog?n=100000" | jq -r ".repositories[]"); do
    for tag in $(curl -s --fail "${DEST_URI}/v2/${repo}/tags/list" | jq -r ".tags[]"); do
        SOURCE_ID=$(tag_to_image_id "${SOURCE_URI}" "${repo}" "${tag}")
        if [ "$SOURCE_ID" = "null" ] ; then
            echo "${SOURCE}/${repo}:${tag} Removed, deleting ${DEST}/${repo}:${tag}"
            DCD=$(curl -s -I -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "http://${DEST}/v2/${repo}/manifests/${tag}" | grep ^Docker-Content-Digest: | cut -c 24- | tr -d '\r')
            curl -s --fail -X DELETE "${DEST_URI}/v2/$repo/manifests/$DCD"
            DELETES_DONE=true
        fi
    done
done

if $UPDATES_DONE || $DELETES_DONE ; then
	echo "Target registry needs garbage collection"
fi
