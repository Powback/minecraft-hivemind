# The fleet fault monitor as a service, so it outlives any terminal session. Polls HQ's /brief on the
# compose network, prints fault changes to its log (docker compose logs -f fleet-watch), and raises
# the alarm-class ones in-game over RCON on the game server's own network.
FROM itzg/rcon-cli:latest AS rcon
FROM alpine:3.20
RUN apk add --no-cache bash curl jq
COPY --from=rcon /rcon-cli /usr/local/bin/rcon-cli
COPY fleet-watch-service.sh /usr/local/bin/fleet-watch
RUN chmod +x /usr/local/bin/fleet-watch
ENTRYPOINT ["/usr/local/bin/fleet-watch"]
