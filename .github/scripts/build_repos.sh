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

main() {
  GOT_DEB=0
  DEB_ARCH=riscv64
  DEB_SOC=sg200x
  COMPONENTS="${DEB_SOC}"
  DEB_POOL="_site/deb/pool/${COMPONENTS:-main}"
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
      deb_tar_files="$(echo "$release" | jq -r '.assets[] | select(.name | endswith("-sd_debs.tar.gz")) | .name')"
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
        deb_component="$(echo ${tar_file} | cut -d '_' -f 1 | sed s/'-sd$'/''/g)"
        deb_compopool="_site/deb/pool/${deb_component}"
        GOT_DEB=1
        mkdir -p "$deb_compopool"
        pushd "$deb_compopool" >/dev/null
        echo "Getting DEB tar"
        wget -q "https://github.com/${repo}/releases/download/${tag}/${tar_file}"
        tar -xzf ${tar_file}
        rm -f ${tar_file}
        #for deb_file in *pinmux*.deb ; do
        #  if [ -e $deb_file ]; then
        #    mkdir -p ../${DEB_SOC}
        #    mv $deb_file ../${DEB_SOC}/
        #  fi
        #done
        popd >/dev/null
      done
    fi
  done < .github/config/package_list.txt

  if [ $GOT_DEB -eq 1 ]
  then
    for component in _site/deb/pool/* ; do
    COMPONENTS="$(basename ${component})"
    DEB_POOL="_site/deb/pool/${COMPONENTS:-main}"
    DEB_DISTS="dists/${SUITE:-stable}"
    DEB_DISTS_COMPONENTS="${DEB_DISTS}/${COMPONENTS:-main}/binary-${DEB_ARCH}"
    pushd _site/deb >/dev/null
    mkdir -p "${DEB_DISTS_COMPONENTS}"
    echo "Scanning all downloaded DEB Packages and creating Packages file."
    dpkg-scanpackages --arch ${DEB_ARCH} pool/${COMPONENTS:-main} > "${DEB_DISTS_COMPONENTS}/Packages"
    gzip -9 > "${DEB_DISTS_COMPONENTS}/Packages.gz" < "${DEB_DISTS_COMPONENTS}/Packages"
    bzip2 -9 > "${DEB_DISTS_COMPONENTS}/Packages.bz2" < "${DEB_DISTS_COMPONENTS}/Packages"
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
      echo "Architectures: ${DEB_ARCH}"
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
