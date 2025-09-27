image_name := env("BUILD_IMAGE_NAME", "void-bootc")
image_tag := env("BUILD_IMAGE_TAG", "latest")
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "ext4")
root_access := env("ROOT_ACCESS_UTIL", "sudo")

build-containerfile $image_name=image_name:
    {{root_access}} podman build -t "${image_name}:latest" .

bootc *ARGS:
    {{root_access}} podman run \
        --rm --privileged --pid=host \
        -it \
        -v /etc/containers:/etc/containers:Z \
        -v /var/lib/containers:/var/lib/containers:Z \
        -v /dev:/dev \
        -e RUST_LOG=trace \
        -v "{{base_dir}}:/data" \
        --security-opt label=type:unconfined_t \
        "{{image_name}}:latest" bootc {{ARGS}}

generate-bootable-image $base_dir=base_dir $filesystem=filesystem:
    #!/usr/bin/env bash
    if [ ! -e "${base_dir}/bootable.img" ] ; then
        fallocate -l 20G "${base_dir}/bootable.img"
    fi
    just bootc install to-disk --composefs-native --via-loopback /data/bootable.img --filesystem "${filesystem}" --wipe --bootloader systemd
