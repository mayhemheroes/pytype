# Build Stage
FROM python:3.11-slim
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y git clang && \
    rm -rf /var/lib/apt/lists/*

RUN pip install atheris

ADD . /src
WORKDIR /src
RUN git submodule update --init
RUN python3 -m pip install .

CMD ["/src/mayhem/fuzz_analyze.py"]
