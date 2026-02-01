#!/bin/bash
generate_hashes() {
  HASH_TYPE="$1"
  HASH_COMMAND="$2"
  echo "${HASH_TYPE}:"
  for component in ${COMPONENTS:-main} ; do
  find "${component}" -type f | while read -r file
  do
    echo " $(${HASH_COMMAND} "$file" | cut -d" " -f1) $(wc -c "$file")"
  done
  done
}

generate_json() {
  CONTENT_VERSION=$1
  CONTENT_FILE=$2
  CONTENT_SHAB64=$(sha512sum ${CONTENT_FILE} | xxd -p -r | basenc --base64 --wrap=0)
  CONTENT_BYTES=$(stat -c %s ${CONTENT_FILE})
  CONTENT_SIZE=${CONTENT_BYTES}
  #CONTENT_BYTES=$(expr $(stat -c %s ${CONTENT_FILE}) + 512)
  #CONTENT_SIZE=$(expr ${CONTENT_BYTES} / 1024)

  cat <<EOF
{
  "version": "${CONTENT_VERSION}",
  "name": "${CONTENT_FILE}",
  "sha512": "${CONTENT_SHAB64}",
  "size": ${CONTENT_SIZE}
}
EOF
}

deb_json() {
  generate_json $2 $1_$2_$3.deb
}

firmware_json() {
  generate_json $2 $1_v$2.tar.xz
}

latest_json() {
  LATEST_VERSION=$2
  LATEST_FILE=$1_$2.tar.gz
  LATEST_SHAB64=$(sha512sum ${LATEST_FILE} | xxd -p -r | basenc --base64 --wrap=0)
  LATEST_BYTES=$(expr $(stat -c %s ${LATEST_FILE}) + 512)
  LATEST_SIZE=$(expr ${LATEST_BYTES} / 1024)

  cat <<EOF
{
  "version": "${LATEST_VERSION}",
  "name": "${LATEST_FILE}",
  "sha512": "${LATEST_SHAB64}",
  "size": ${LATEST_SIZE}
}
EOF
}

main() {
  GOT_DEB=0
  DEB_ARCH=riscv64
  DEB_SOC=sg200x
  COMPONENTS="${DEB_SOC}"
  DEB_POOL="_site/deb/pool/${COMPONENTS:-main}"
  DEB_DISTS_ARCHS="arm64 riscv64"
  DEB_DISTS="dists/${SUITE:-stable}"
  DEB_DISTS_COMPONENTS="${DEB_DISTS}/${COMPONENTS:-main}/binary-all"
  GPG_TTY=""
  export GPG_TTY
  echo "Parsing the repo list"
  while IFS= read -r repo
  do
    if release=$(curl -fqs https://api.github.com/repos/${repo}/releases/latest)
    then
      tag="$(echo "$release" | jq -r '.tag_name')"
      deb_files="$(echo "$release" | jq -r '.assets[] | select(.name | endswith(".deb")) | .name')"
      deb_tar_files="$(echo "$release" | jq -r '.assets[] | select(.name | endswith("_debs.tar.gz")) | .name')"
      firmware_tar_files="$(echo "$release" | jq -r '.assets[] | select(.name | match("_firmware_.*\\.tar\\..z")) | .name')"
      kvmadmin_tar_files="$(echo "$release" | jq -r '.assets[] | select(.name | endswith("-kvmadmin.tar.gz")) | .name')"
      latest_zip_files="$(echo "$release" | jq -r '.assets[] | select(.name | endswith("-latest.zip")) | .name')"
      echo "Parsing repo $repo at $tag"
      for deb_file in $deb_files ; do
      if [ -n "$deb_file" ]
      then
        GOT_DEB=1
        mkdir -p "$DEB_POOL"
        pushd "$DEB_POOL" >/dev/null
        echo "Getting DEB"
        wget -q "https://github.com/${repo}/releases/download/${tag}/${deb_file}"
        popd >/dev/null
      fi
      done
      for tar_file in $deb_tar_files ; do
        if echo ${tar_file} | grep -q '-emmc_' ; then
          sd_file="$(echo ${tar_file} | sed s/'-emmc_'/'-sd_'/g)"
          if echo $deb_tar_files | grep -q ${sd_file} ; then
            continue
          fi
        fi
        deb_component="$(echo ${tar_file} | cut -d '_' -f 1 | sed s/'-emmc$'/''/g | sed s/'-sd$'/''/g)"
        deb_compopool="_site/deb/pool/${deb_component}"
        GOT_DEB=1
        mkdir -p "$deb_compopool"
        pushd "$deb_compopool" >/dev/null
        echo "Getting DEB tar"
        wget -q "https://github.com/${repo}/releases/download/${tag}/${tar_file}"
        tar -xzf ${tar_file}
        rm -f ${tar_file}
        for deb_file in *pinmux*.deb ; do
          if [ -e $deb_file ]; then
            mkdir -p ../${DEB_SOC}
            mv $deb_file ../${DEB_SOC}/
          fi
        done
        tar_component=-
        tar_version=-
        tar_sdk_ver=-
        if [ "${deb_component}" = "nanokvmpro-kvm" ]; then
          tar_component=nanokvm_pro
          for deb_file in nanokvmpro_*.deb kvmcomm_*.deb pikvm_*.deb ; do
            [ -e $deb_file ] || continue
            deb_name=`echo $deb_file | cut -d '_' -f 1`
            deb_ver=`echo $deb_file | cut -d '_' -f 2`
            deb_arch=`echo $deb_file | cut -d '_' -f 3 | cut -d '.' -f 1`
            tar_version=${deb_ver}
            tar_sdk_ver=glibc_${deb_arch}
            mkdir -p ${tar_component}_${tar_version}
            cp -p $deb_file ${tar_component}_${tar_version}/
            deb_json ${deb_name} ${deb_ver} ${deb_arch} > ${tar_component}_${tar_version}/${deb_name}_${deb_ver}.json
          done
          tar -czf ${tar_component}_${tar_version}.tar.gz ${tar_component}_${tar_version}
          latest_json ${tar_component} ${tar_version} > ${tar_component}_latest.json
          rm -rf ${tar_component}_${tar_version}
        fi
        popd >/dev/null
        if [ ${tar_sdk_ver} != "-" ]; then
          tar_compopool="_site/${tar_component}/${tar_sdk_ver}"
          mkdir -p "$tar_compopool"
          mv "$deb_compopool"/${tar_component}_${tar_version}.tar.gz "$tar_compopool"/
          mv "$deb_compopool"/${tar_component}_latest.json "$tar_compopool"/
          mkdir -p "$tar_compopool"/preview
          cp -p "$tar_compopool"/*.tar.* "$tar_compopool"/preview/
          cp -p "$tar_compopool"/*.json "$tar_compopool"/preview/
        fi
      done
     for firmware_tar_file in $firmware_tar_files ; do
      if [ -n "$firmware_tar_file" ]
      then
        firmware_new_file="$(echo ${firmware_tar_file} | cut -d '-' -f 2-)"
        tar_name="$(echo ${firmware_new_file} | cut -d '_' -f 1-2)"
        tar_ver="$(echo ${firmware_new_file} | cut -d '_' -f 3- | sed s/'\.tar\..z$'/''/g | tr -d 'v')"
        tar_component="$(echo ${firmware_tar_file} | cut -d '-' -f 1)"
        tar_arch=${DEB_ARCH}
        [ "${tar_component}" != "nanokvmpro" ] || tar_arch=arm64
        [ "${tar_component}" != "nanokvmpro" ] || tar_component=nanokvm_pro
        tar_sdk_ver=glibc_${tar_arch}
        tar_compopool="_site/${tar_component}/${tar_sdk_ver}"
        mkdir -p "$tar_compopool"
        pushd "$tar_compopool" >/dev/null
        echo "Getting TAR"
        wget -q "https://github.com/${repo}/releases/download/${tag}/${firmware_tar_file}"
        popd >/dev/null
        mkdir -p "$tar_compopool"/pro
        mv "$tar_compopool"/${firmware_tar_file} "$tar_compopool"/pro/${firmware_new_file}
        pushd "$tar_compopool"/pro >/dev/null
        firmware_json ${tar_name} ${tar_ver} > firmware_${tar_ver}.json
        popd >/dev/null
      fi
      done
      for kvmadmin_tar_file in $kvmadmin_tar_files ; do
      if [ -n "$kvmadmin_tar_file" ]
      then
        tar_component="$(echo ${kvmadmin_tar_file} | cut -d '-' -f 1)"
        tar_arch=${DEB_ARCH}
        [ "${tar_component}" != "nanokvmpro" ] || tar_arch=arm64
        [ "${tar_component}" != "nanokvmpro" ] || tar_component=nanokvm_pro
        tar_sdk_ver=glibc_${tar_arch}
        tar_compopool="_site/${tar_component}/${tar_sdk_ver}"
        mkdir -p "$tar_compopool"
        pushd "$tar_compopool" >/dev/null
        echo "Getting TAR"
        wget -q "https://github.com/${repo}/releases/download/${tag}/${kvmadmin_tar_file}"
        popd >/dev/null
        mkdir -p "$tar_compopool"/resources
        mv "$tar_compopool"/${kvmadmin_tar_file} "$tar_compopool"/resources/kvmadmin.tar.gz
      fi
      done
      for latest_zip_file in $latest_zip_files ; do
      if [ -n "$latest_zip_file" ]
      then
        GOT_ZIP=1
        zip_sdk_ver=glibc_${DEB_ARCH}
        echo $repo | grep -q sophgo-sg200x-debian || zip_sdk_ver=musl_${DEB_ARCH}
        zip_component="$(echo ${latest_zip_file} | cut -d '-' -f 1)"
        zip_compopool="_site/${zip_component}/${zip_sdk_ver}"
        mkdir -p "$zip_compopool"
        pushd "$zip_compopool" >/dev/null
        echo "Getting ZIP"
        wget -q "https://github.com/${repo}/releases/download/${tag}/${latest_zip_file}"
        mv ${latest_zip_file} latest.zip
        rm -f latest
        unzip latest.zip latest/*
        zip_version=$(cat latest/version)
        mv latest ${zip_component}_${zip_version}
        cp -p ${zip_component}_${zip_version}/version latest
        tar -czf ${zip_component}_${zip_version}.tar.gz ${zip_component}_${zip_version}
        latest_json ${zip_component} ${zip_version} > latest.json
        rm -rf ${zip_component}_${zip_version}
        popd >/dev/null
      fi
      done
    fi
  done < .github/config/package_list.txt

  if [ $GOT_DEB -eq 1 ]
  then
    for component in _site/deb/pool/* ; do
      COMPONENTS="$(basename ${component})"
      DEB_POOL="_site/deb/pool/${COMPONENTS:-main}"
      DEB_DISTS="dists/${SUITE:-stable}"
      pushd _site/deb >/dev/null
      for DEB_DISTS_ARCH in $DEB_DISTS_ARCHS ; do
        DEB_DISTS_COMPONENTS="${DEB_DISTS}/${COMPONENTS:-main}/binary-${DEB_DISTS_ARCH}"
        mkdir -p "${DEB_DISTS_COMPONENTS}"
        echo "Scanning all downloaded DEB Packages and creating Packages file."
        dpkg-scanpackages --arch ${DEB_DISTS_ARCH} pool/${COMPONENTS:-main} > "${DEB_DISTS_COMPONENTS}/Packages"
        gzip -9 > "${DEB_DISTS_COMPONENTS}/Packages.gz" < "${DEB_DISTS_COMPONENTS}/Packages"
        bzip2 -9 > "${DEB_DISTS_COMPONENTS}/Packages.bz2" < "${DEB_DISTS_COMPONENTS}/Packages"
      done
      popd >/dev/null
    done
    pushd "_site/deb/${DEB_DISTS}" >/dev/null
    rm -f *Release*
    COMPONENTS=$(ls -d * | tr '\n' ' ')
    echo "Making Release file"
    {
      echo "Origin: ${ORIGIN}"
      echo "Label: ${REPO_OWNER}"
      echo "Suite: ${SUITE:-stable}"
      echo "Codename: ${SUITE:-stable}"
      echo "Version: 1.0"
      echo "Architectures: ${DEB_DISTS_ARCHS}"
      echo "Components: ${COMPONENTS:-main}"
      echo "Description: ${DESCRIPTION:-A repository for packages released by ${REPO_OWNER}}"
      echo "Date: $(date -Ru)"
      generate_hashes MD5Sum md5sum
      generate_hashes SHA1 sha1sum
      generate_hashes SHA256 sha256sum
    } > Release
    echo "Signing Release file"
    gpg --detach-sign --armor --sign > Release.gpg < Release
    gpg --detach-sign --armor --sign --clearsign > InRelease < Release
    echo "DEB repo built"
    popd >/dev/null
  fi
}
main
