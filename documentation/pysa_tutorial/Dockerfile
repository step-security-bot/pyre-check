FROM ubuntu:18.04@sha256:152dc042452c496007f07ca9127571cb9c29697f42acbfad72324b2bb2e43c98

RUN apt-get update

RUN apt-get install -y build-essential python3.7 python3.7-dev python3-pip python3.7-venv libssl-dev libffi-dev
RUN apt-get install -y git

# update pip
RUN python3.7 -m pip install pip --upgrade
RUN python3.7 -m pip install wheel

RUN mkdir /pyre-check
WORKDIR /pyre-check
COPY . .

RUN pip3 install psutil
RUN pip3 install pyre-check fb-sapp django-stubs
