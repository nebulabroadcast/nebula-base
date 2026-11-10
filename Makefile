IMAGE=nebulabroadcast/nebula-worker-base:2026.11
.PHONY: build test shell shell-nvidia shell-vaapi dist

build:
	docker build -t $(IMAGE) .

# Pass additional docker arguments to test hardware encoding, e.g.
#   make test DOCKER_ARGS="--device /dev/dri"
#   make test DOCKER_ARGS="--runtime=nvidia --gpus all"
test:
	docker run --rm $(DOCKER_ARGS) -v ./test.sh:/test.sh:ro $(IMAGE) bash /test.sh

shell:
	docker run --rm -it  $(IMAGE) /bin/bash

shell-nvidia:
	docker run --rm -it --runtime=nvidia --gpus all -v ./test:/app $(IMAGE) /bin/bash

shell-vaapi:
	docker run --rm -it --device /dev/dri -v ./test:/app $(IMAGE) /bin/bash

dist: build
	docker push $(IMAGE)
