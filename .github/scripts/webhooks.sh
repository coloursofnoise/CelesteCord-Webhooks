#!/usr/bin/env bash

if [ -z "$ID_FILE" ]; then
    ID_FILE='ids'
fi

POST_PROCESS='grep .'
case "$(uname)" in CYGWIN*|MINGW*|MSYS*)
    curl -V | grep Unicode || POST_PROCESS='iconv -c -f UTF-8 -t ASCII//TRANSLIT'
    ;;
esac

# args:
#   Webhook
webhook_url() {
    if [ -z "$TEST_WEBHOOK_URL" ]; then
        local varname=$(echo ${1}_WEBHOOK | tr [:lower:] [:upper:])
        echo ${!varname}
    else
        echo $TEST_WEBHOOK_URL
    fi
}

# args:
#   Webhook
# exit status:
#   0: success
#      echo: array of message IDs
#   1: URL not valid/could not be found
#   2: webhook is uninitialized
#   3: cached webhook message could not be found
webhook_status() {
    local HOOK="$1"
    local WEBHOOK_URL=$(webhook_url $HOOK)
    if ! curl -o /dev/null -f "$WEBHOOK_URL"; then
        return 1
    fi

    test $TEST_SEND && return 2

    if ! test -f "./$HOOK/$ID_FILE" && test -f "./$HOOK/new"; then
        rm "./$HOOK/new"
        return 2
    fi

    local IDS=()
    readarray -t IDS < <(cat ./$HOOK/$ID_FILE | tr -d '\r')
    for MSG in ${IDS[@]}; do
        sleep 0.05
        if ! curl -o /dev/null -f "$WEBHOOK_URL/messages/$MSG"; then
            return 3
        fi
    done

    echo ${IDS[@]}
    return 0
}

# args:
#   Webhook URL
#   HTTP Method
#   Webhook name
#   Message index (file name)
# echo:
#   Result of curl request.
send_message() {
    embed_query='--argjson embeds []'
    content_query='--argjson content null'
    test -f $3/embeds/$4 && embed_query="--slurpfile embeds $3/embeds/$4"
    test -f $3/messages/$4 && content_query="--rawfile content $3/messages/$4"
    curl \
        -X $2 \
        -H "Content-Type: application/json" \
        "$1?wait=true" \
        -d "$(
            jq -ncj \
            $content_query \
            $embed_query \
            '{content: $content, embeds: $embeds, allowed_mentions: {parse: []}}' | \
            perl -e '$json = <>; $json =~ s/<\{\{ (.+?) \}\}>/`cat $1 | jq -sR | head -c -3 | tail -c +2`/ge; print $json' | \
            $POST_PROCESS \
        )" \
        -w '%{stderr}Return Code:%{http_code}\n%{stdout}\n'
}

# --EXECUTION START--
echo 'Retrieving changed files'
CHANGED=$(git diff-tree --no-commit-id --name-only --diff-filter=d -r $BEFORE_SHA..$GITHUB_SHA)

# Get all changed files that belong to a webhook
declare -A WEBHOOKS
for file in $CHANGED; do
    if [[ "$(basename "$(dirname $file)")" == 'embeds' && -e $file && -e ${file/embeds/messages} ]]; then
        file=${file/embeds/messages}
    fi
    if [[ "$(basename "$(dirname $file)")" == 'messages' && -e $file ]]; then
        KEY="$(echo $file | cut -d '/' -f1)"
        if [[ ! " ${WEBHOOKS[$KEY]}" == *" $file "* ]]; then
            WEBHOOKS[$KEY]+="$file "
        fi
    fi
done

for HOOK in "${!WEBHOOKS[@]}"; do
    echo "Checking status of $HOOK"
    IDS=($(webhook_status $HOOK))
    STATUS=$?
    if [ $STATUS == 0 ]; then
        # Update changed messages or append new ones
        WEBHOOK_URL=$(webhook_url $HOOK)

        for file in ${WEBHOOKS[$HOOK]}; do
            IDX=$(basename "$file")
            MSG_ID=${IDS[$IDX]}

            sleep 0.05
            if [ "$MSG_ID" == "" ]; then
                IDS_UPDATED="TRUE"
                echo "Appending message $IDX to $HOOK"
                response=$(send_message $WEBHOOK_URL POST $HOOK $IDX)
                echo $response | jq -r '.id' >>"./$HOOK/$ID_FILE"
            else
                echo "Updating message $MSG_ID for $HOOK"
                send_message $WEBHOOK_URL/messages/$MSG_ID PATCH $HOOK $IDX >/dev/null
                echo $response
            fi
        done
    elif [ $STATUS == 2 ]; then
        # Send new messages
        IDS_UPDATED="TRUE"
        echo "No existing messages for $HOOK"
        WEBHOOK_URL=$(webhook_url $HOOK)
        for file in ./$HOOK/messages/*; do
            sleep 0.05
            IDX=$(basename "$file")
            echo "Sending message $IDX for $HOOK"
            response=$(send_message $WEBHOOK_URL POST $HOOK $IDX)
            echo $response | jq -r '.id' >>"./$HOOK/$ID_FILE"
        done

    else
        echo "::error ::Check failed for $HOOK with status $STATUS"
        if [ ${#WEBHOOKS[@]} == 1 ]; then
            exit 1
        fi
    fi
done

# Trigger PR to update message IDs
if [ "$IDS_UPDATED" == "TRUE" ]; then
    echo "ids_updated=true" >>$GITHUB_ENV
fi
