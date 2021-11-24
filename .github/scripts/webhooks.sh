webhook_status () {
    local HOOK="$1"
    local varname=$(echo ${HOOK}_WEBHOOK | tr [:lower:] [:upper:])
    local WEBHOOK_URL=${!varname}
    if ! curl -o /dev/null -f "$WEBHOOK_URL" ; then
        return 1
    fi

    if ! test -f "./$HOOK/ids" && test -f "./$HOOK/new" ; then
        rm "./$HOOK/new"
        return 2
    fi

    local IDS=()
    readarray -t IDS < "./$HOOK/ids"
    for MSG in ${IDS[@]} ; do
        sleep 0.05
        if ! curl -o /dev/null -f "$WEBHOOK_URL/messages/$MSG" ; then
            return 3
        fi
    done

    echo ${IDS[@]}
    return 0
}

send_message () {
    curl \
        -X POST \
        -H "Content-Type: application/json" \
        "$1?wait=true" \
        -d "$(jq -n \
            --arg content "$(cat $2)" \
            '{content: $content, allowed_mentions: {parse: []}}' \
        )"
}

echo 'Retrieving changed files'
CHANGED=$(git diff-tree --no-commit-id --name-only -r $GITHUB_SHA)

declare -a WEBHOOKS
for file in $CHANGED
do
    if [ "$(basename "$(dirname $file)")" == 'messages' ]
    then
        WEBHOOKS+=("$(echo $file | cut -d '/' -f1)")
    fi
done
WEBHOOKS=($(for HOOK in "${WEBHOOKS[@]}"; do echo "$HOOK";done | sort | uniq | xargs))

for HOOK in "${WEBHOOKS[@]}" ; do
    echo "Checking status of $HOOK"
    IDS=($(webhook_status $HOOK))
    STATUS=$?
    if [ $STATUS == 0 ] ; then
        varname=$(echo ${HOOK}_WEBHOOK | tr [:lower:] [:upper:])
        WEBHOOK_URL=${!varname}

        for file in $CHANGED ; do
            if [[ "$file" == *"$HOOK/messages"* ]] ; then
                IDX=$(basename "$file")
                MSG_ID=${IDS[$IDX]}

                sleep 0.05
                if [ "$MSG_ID" == "" ]; then
                    IDS_UPDATED="TRUE"
                    echo "Appending message $IDX to $HOOK"
                    response=$(send_message $WEBHOOK_URL $file)
                    echo $response | jq -r '.id' >> "./$HOOK/ids"
                else
                    echo "Updating message $MSG_ID for $HOOK"
                    curl \
                        -X PATCH \
                        -H "Content-Type: application/json" \
                        "$WEBHOOK_URL/messages/$MSG_ID?wait=true" \
                        -d "$(jq -n \
                            --arg content "$(cat $file)" \
                            '{content: $content}' \
                        )"
                fi
            fi
        done
    elif [ $STATUS == 2 ] ; then
        IDS_UPDATED="TRUE"
        echo "No existing messages for $HOOK"
        varname=$(echo ${HOOK}_WEBHOOK | tr [:lower:] [:upper:])
        WEBHOOK_URL=${!varname}
        for file in ./$HOOK/messages/* ; do
            sleep 0.05
            echo "Sending message "$(basename "$file")" for $HOOK"
            response=$(send_message $WEBHOOK_URL $file)
            echo $response | jq -r '.id' >> "./$HOOK/ids"
        done

    else
        echo "::error ::Check failed for $HOOK with status $STATUS"
        if [ ${#WEBHOOKS[@]} == 1 ] ; then
            exit 1
        fi
    fi
done

if [ "$IDS_UPDATED" == "TRUE" ] ; then
    echo "ids_updated=true" >> $GITHUB_ENV
fi
