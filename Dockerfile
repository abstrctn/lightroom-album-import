FROM alpine:3.17

RUN apk update && apk add bash exiftool curl jq

COPY main.sh /main.sh
COPY metadata-translation.csv /metadata-translation.csv

ENTRYPOINT /main.sh