FROM docker:dind

CMD ["dockerd", "--host", "tcp://0.0.0.0:2376", "--tls=false"]