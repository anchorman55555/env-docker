FROM debian:bookworm-slim
RUN echo "postfix postfix/mailname string crm.cifroweek.com" | debconf-set-selections &&     echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections &&     apt-get update -q &&     DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends         postfix libsasl2-modules libsasl2-2 ca-certificates
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 25
ENTRYPOINT ["/entrypoint.sh"]
