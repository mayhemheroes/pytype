# Build Stage
FROM fuzzers/atheris:2.0.7-python3.9

ADD . /src
WORKDIR /src
RUN git submodule update --init
RUN python3 -m pip install .

CMD ["/src/mayhem/fuzz_analyze.py"]
