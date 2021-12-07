# HOOK
get_webhook() {
    local varname=$(echo ${1}_WEBHOOK | tr [:lower:] [:upper:])
    echo ${!varname}
}

# HOOK
webhook_status () {
    local HOOK="$1"
    local WEBHOOK_URL=$(get_webhook $HOOK)
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

# WEBHOOK_URL PROTOCOL HOOK MGS_IDX
send_message () {
    embed_query='--argjson embeds []'
    test -f $3/embeds/$4 && embed_query="--slurpfile embeds $3/embeds/$4"
    curl \
        -X $2 \
        -H "Content-Type: application/json" \
        "$1?wait=true" \
        -d "$(jq -ncj \
            --arg content "$(cat $3/messages/$4)" \
            $embed_query \
            '{content: $content, embeds: $embeds, allowed_mentions: {parse: []}}' | \
            perl -e '$json = <>; $json =~ s/<\{\{ (.+?) \}\}>/`cat $1 | jq -sR | head -c -3 | tail -c +2`/ge; print $json' \
        )"
}

echo 'Retrieving changed files'
CHANGED=$(git diff-tree --no-commit-id --name-only -r $GITHUB_SHA)

declare -a WEBHOOKS
for file in $CHANGED; do
    folder=$(basename "$(dirname $file)")
    if [[ "$folder" == 'embeds' && -e $file && -e ${file/embeds/messages} ]]; then
        file=${file/embeds/messages}
        folder=${folder/embeds/messages}
    fi
    if [[ "$folder" == 'messages' && -e $file ]]; then
        WEBHOOKS+=("$(echo $file | cut -d '/' -f1)")
    fi
done
WEBHOOKS=($(for HOOK in "${WEBHOOKS[@]}"; do echo "$HOOK";done | sort | uniq | xargs))

for HOOK in "${WEBHOOKS[@]}" ; do
    echo "Checking status of $HOOK"
    IDS=($(webhook_status $HOOK))
    STATUS=$?
    if [ $STATUS == 0 ] ; then
        WEBHOOK_URL=$(get_webhook $HOOK)

        for file in $CHANGED ; do
            if [[ "$file" == *"$HOOK/messages"* ]] ; then
                IDX=$(basename "$file")
                MSG_ID=${IDS[$IDX]}

                sleep 0.05
                if [ "$MSG_ID" == "" ]; then
                    IDS_UPDATED="TRUE"
                    echo "Appending message $IDX to $HOOK"
                    response=$(send_message $WEBHOOK_URL POST $HOOK $IDX)
                    echo $response | jq -r '.id' >> "./$HOOK/ids"
                else
                    echo "Updating message $MSG_ID for $HOOK"
                    send_message $WEBHOOK_URL/messages/$MSG_ID PATCH $HOOK $IDX
                fi
            fi
        done
    elif [ $STATUS == 2 ] ; then
        IDS_UPDATED="TRUE"
        echo "No existing messages for $HOOK"
        WEBHOOK_URL=$(get_webhook $HOOK)
        for file in ./$HOOK/messages/* ; do
            sleep 0.05
            IDX=$(basename "$file")
            echo "Sending message $IDX for $HOOK"
            response=$(send_message $WEBHOOK_URL POST $HOOK $IDX)
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
