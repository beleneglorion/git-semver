#!/bin/bash

# todo add bats unit test :)

set -o errexit -o pipefail

NAT='0|[1-9][0-9]*'
ALPHANUM='[0-9]*[A-Za-z-][0-9A-Za-z-]*'
IDENT="$NAT|$ALPHANUM"
FIELD='[0-9A-Za-z-]+'
SEMVER_REGEX="^[vV]?($NAT)\\.($NAT)\\.($NAT)(\\-(${IDENT})(\\.(${IDENT}))*)?(\\+${FIELD}(\\.${FIELD})*)?$"
DEBUG_MODE=${DEBUG_MODE:-0}
VERSION_PREFIX=${VERSION_PREFIX:""}

info () {
 local msg=$@
 if [[ $(declare -p ${msg} 2> /dev/null | grep -q '^declare \-a')  ]]; then
 printf "\r[ \033[00;34m..\033[0m ] Array : \n" >&2
  for line in "${msg[@]}"
    do
       printf "\r - [ \033[00;34m..\033[0m ] $line\n" >&2
    done
 else
    printf "\r [ \033[00;34m..\033[0m ] $msg\n" >&2
 fi
}

user () {
  printf "\r  [ \033[0;33m??\033[0m ] $1\n"
}

success () {
  printf "\r\033[2K  [ \033[00;32mOK\033[0m ] $1\n"
}

fail () {
  printf "\r\033[2K  [\033[0;31mFAIL\033[0m] $1\n"
  echo ''
  exit
}

failure() {
  local lineno=$1
  local msg=$2
  echo "Failed at $lineno: $msg"
}
trap 'failure ${LINENO} "$BASH_COMMAND"' ERR

debug() {
 if [[ "${DEBUG_MODE}" -eq "1" ]]; then
   info $*
 fi
}

usage() {
	cat <<-EOF
		Usage: $(basename-git "$0") [command]

		This script automates semantic versioning. Requires a valid change log at CHANGELOG.md.

		See https://github.com/markchalloner/git-semver for more detail.

		Commands
		 get                                                   Gets the current version (tag)
		 major [--dryrun] [-p <pre-release>] [-b <build>]      Generates a tag for the next major version and echos to the screen
		 minor [--dryrun] [-p [<pre-release> [-b <build>]      Generates a tag for the next minor version and echos to the screen
		 patch|next [--dryrun] [-p <pre-release>] [-b <build>] Generates a tag for the next patch version and echos to the screen
		 release [--dryrun]                                    Generates a tag for the core version (remove pre-release and build part)
		 pre-release [--dryrun] -p <pre-release> [-b <build>]  Generates a tag for a pre-release version and echos to the screen
		 build [--dryrun] -b <build>                           Generates a tag for a build and echos to the screen
		 parse <version>                                       Return full and splited part of version
		 compare <version1> <version1>                         Compare versions
		 help                                                  This message

	EOF
	exit
}

########################################
# Helper functions
########################################

function basename-git() {
    basename "$1" | tr '-' ' ' | sed 's/.sh$//g'
}

########################################
# Plugin functions
########################################

plugin-output() {
    local type="$1"
    local name="$2"
    local output=
    while IFS='' read -r line
    do
        if [[ -z "${output}" ]]
        then
            echo -e "\n$type plugin \"$name\":\n"
            output=1
        fi
        echo "  $line"
    done
}

plugin-list() {
    local types=("User" "Project")
    local dirs=("${DIR_HOME}" "${DIR_ROOT}")
    local plugin_dir=
    local plugin_type=
    local total=${#dirs[*]}
    for (( i=0; i <= $((total-1)); i++ ))
    do
        plugin_type=${types[${i}]}
        plugin_dir="${dirs[${i}]}/.git-semver/plugins"
        if [[ -d "${plugin_dir}" ]]
        then
            find "${plugin_dir}" -maxdepth 1 -type f -exec echo "${plugin_type},{}" \;
        fi
    done
}

plugin-run() {
    # shellcheck disable=SC2155
    local plugins="$(plugin-list)"
    local version_new="$1"
    local version_current="$2"
    local status=0
    local type=
    local typel=
    local path=
    local name=
    for i in ${plugins}
    do
        type=${i%%,*}
        typel=$(echo "${type}" | tr '[:upper:]' '[:lower:]')
        path=${i##*,}
        name=$(basename "${path}")
        ${path} "${version_new}" "${version_current}" "${GIT_HASH}" "${GIT_BRANCH}" "${DIR_ROOT}" 2>&1 |
            plugin-output "${type}" "${name}"
        RETVAL=${PIPESTATUS[0]}
        case ${RETVAL} in
            0)
                ;;
            111|1)
                echo -e "\nError: Warning from ${typel} plugin \"${name}\", ignoring"
                ;;
            112)
                echo -e "\nError: Error from ${typel} plugin \"${name}\", unable to version"
                status=1
                ;;
            113)
                echo -e "\nError: Fatal error from ${typel} plugin \"${name}\", unable to version, quitting immediately"
                return 1
                ;;
            *)
                echo -e "\nError: Unknown error from ${typel} plugin \"${name}\", ignoring"
        esac
    done
    return ${status}
}

plugin-debug() {
    local new version major patch new
    version=$(version-get)
    major=$(version-parse-major "${version}")
    minor=$(version-parse-minor "${version}")
    patch=$(version-parse-patch "${version}")

    new=0.1.0
    if [[ -n "$version" ]]
    then
        new=${major}.${minor}.$((patch+1))
    fi

    plugin-run "$new" "$version"
}

validate-pre-release() {
    local pre_release=$1
    if ! [[ "$pre_release" =~ ^[0-9A-Za-z.-]*$ ]] || # Not alphanumeric, `-` and `.`
        [[ "$pre_release" =~ (^|\.)\. ]] ||          # Empty identifiers
        [[ "$pre_release" =~ \.(\.|$) ]] ||          # Empty identifiers
        [[ "$pre_release" =~ \.0[0-9] ]]             # Leading zeros
    then
        echo "Error: pre-release is not valid."
        exit 1
    fi
}

validate-build() {
    local build=$1
    if ! [[ "$build" =~ ^[0-9A-Za-z.-]*$ ]] || # Not alphanumeric, `-` and `.`
        [[ "$build" =~ (^|\.)\. ]] ||          # Empty identifiers
        [[ "$build" =~ \.(\.|$) ]]             # Empty identifiers
    then
        echo "Error: build metadata is not valid."
        exit 1
    fi
}

validate-version() {
  local version=$1
  debug "version to validate $version"
  debug "SEMVER_REGEX $SEMVER_REGEX"
  if [[ "$version" =~ $SEMVER_REGEX ]]; then
    # if a second argument is passed, store the result in var named by $2
    if [[ "$#" -eq "2" ]]; then
      local major=${BASH_REMATCH[1]}
      local minor=${BASH_REMATCH[2]}
      local patch=${BASH_REMATCH[3]}
      local prere=${BASH_REMATCH[4]}
      local build=${BASH_REMATCH[8]}
      eval "$2=(\"$major\" \"$minor\" \"$patch\" \"$prere\" \"$build\")"
    else
      echo "$version"
    fi
  else
    error "version $version does not match the semver scheme 'X.Y.Z(-PRERELEASE)(+BUILD)'. "
  fi
}

is-nat() {
    [[ "$1" =~ ^($NAT)$ ]]
}

is-null() {
    [[ -z "$1" ]]
}

order-nat() {
    [[ "$1" -lt "$2" ]] && { echo -1 ; return ; }
    [[ "$1" -gt "$2" ]] && { echo 1 ; return ; }
    echo 0
}

order-string() {
    [[ $1 < $2 ]] && { echo -1 ; return ; }
    [[ $1 > $2 ]] && { echo 1 ; return ; }
    echo 0
}

# given two (named) arrays containing NAT and/or ALPHANUM fields, compare them
# one by one according to semver 2.0.0 spec. Return -1, 0, 1 if left array ($1)
# is less-than, equal, or greater-than the right array ($2).  The longer array
# is considered greater-than the shorter if the shorter is a prefix of the longer.
#
compare-fields() {
    local l="$1[@]"
    local r="$2[@]"
    local leftfield=( "${!l}" )
    local rightfield=( "${!r}" )
    local left
    local right

    local i=$(( -1 ))
    local order=$(( 0 ))

    while true
    do
        [[ $order -ne 0 ]] && { echo ${order} ; return ; }

        : $(( i++ ))
        left="${leftfield[$i]}"
        right="${rightfield[$i]}"

        is-null "$left" && is-null "$right" && { echo 0  ; return ; }
        is-null "$left"                     && { echo -1 ; return ; }
                           is-null "$right" && { echo 1  ; return ; }

        is-nat "$left" &&  is-nat "$right" && { order=$(order-nat "$left" "$right") ; continue ; }
        is-nat "$left"                     && { echo -1 ; return ; }
                           is-nat "$right" && { echo 1  ; return ; }
                                              { order=$(order-string "$left" "$right") ; continue ; }
    done
}

version-compare() {
  local order V  V_
  validate-version "$1" V
  validate-version "$2" V_

  # compare major, minor, patch

  local left=( "${V[0]}" "${V[1]}" "${V[2]}" )
  local right=( "${V_[0]}" "${V_[1]}" "${V_[2]}" )

  order=$(compare-fields left right)
  [[ "$order" -ne 0 ]] && { echo "$order" ; return ; }

  # compare pre-release ids when M.m.p are equal

  local prerel="${V[3]:1}"
  local prerel_="${V_[3]:1}"
  local left=( ${prerel//./ } )
  local right=( ${prerel_//./ } )

  # if left and right have no pre-release part, then left equals right
  # if only one of left/right has pre-release part, that one is less than simple M.m.p

  [[ -z "$prerel" ]] && [[ -z "$prerel_" ]] && { echo 0  ; return ; }
  [[ -z "$prerel" ]]                      && { echo 1  ; return ; }
                      [[ -z "$prerel_" ]] && { echo -1 ; return ; }

  # otherwise, compare the pre-release id's

  compare-fields left right
}


########################################
# Version functions
########################################

version-parse-major() {
    echo "$1" | cut -d "." -f1 | sed "s/^${VERSION_PREFIX}//g"
}

version-parse-minor() {
    echo "$1" | cut -d "." -f2
}

version-parse-patch() {
    echo "$1" | cut -d "." -f3 | sed 's/[-+].*$//g'
}

version-parse-pre-release() {
    echo "$1" | cut -d "." -f3- | grep -o '\-[0-9A-Za-z.]\+'
}

version-parse-pre-release-pure() {
    echo "$1" | cut -d "." -f3- | grep -oP "^[0-9]*\-?\K[A-Za-z0-9\.\-]*"
}

version-parse-build() {
    echo "$1" | cut -d "." -f3 | grep -o '\+[0-9A-Za-z.]'|cut -d "+" -f 2
}

version-parse() {
    # shellcheck disable=SC2155
    local version=$(version-get)
    # shellcheck disable=SC2155
    local major=$(version-parse-major "${version}")
    # shellcheck disable=SC2155
    local minor=$(version-parse-minor "${version}")
    # shellcheck disable=SC2155
    local patch=$(version-parse-patch "${version}")
    # shellcheck disable=SC2155
    local pre_release=$(version-parse-pre-release-pure "${version}")
    # shellcheck disable=SC2155
    local build=$(version-parse-build "${version}")
    echo "FULL_VERSION=${version}"
    echo "MAJOR_VERSION=${major}"
    echo "MINOR_VERSION=${minor}"
    echo "PATCH_VERSION=${patch}"
    echo "PRE_RELEASE=${pre_release}"
    echo "BUILD=${build}"
}


version-get() {
    local sort_args version_main version version_pre_releases pre_release_id_count sorted_version tags pre_release_id_index
    tags=$(git tag --sort=v:refname --merged)
    sorted_version=$(
        echo "$tags" |
            grep -oP "^${VERSION_PREFIX}\K[0-9]+\.[0-9]+\.[0-9]+.*" |
            awk -F '[-+]' '{ print $1 }' |
            uniq |
            sort -t '.' -k 1,1n -k 2,2n -k 3,3n  |
            awk -v VERSION_PREFIX="${VERSION_PREFIX}" '{print VERSION_PREFIX $1}'
    )
    debug "sorted version ${sorted_version}"
    debug "sorted tags ${tags}"
    version_main=$(echo "$sorted_version" | tail -n 1)
    debug "version_main ${version_main}"
    version_pre_release=$(
        local  version_pre_releases pre_release_id_count
        if [[ $(echo "$tags" | grep -P "^${version_main}\$" ) ]]; then
          debug "version_main exit don't search pre-relase"
          echo ""
          exit 0
        fi

        version_pre_releases=$(
            if [[  $(echo "$tags" | grep "^${version_main//./\\.}")  ]]; then
               echo "$tags" | grep "^${version_main//./\\.}" |  awk -F '-' '{ print $2 }'
            else
              echo ""
            fi
        )
         debug "version_pre_releases 1 ${version_pre_releases}"
         if [[ -n  ${version_pre_releases} ]]; then
          debug "count pre release"
           pre_release_id_count=$(
              echo "${version_pre_releases}" | sed '/^[[:space:]]*$/d' | awk 'BEGIN{ max = 0 }  { if (max < length) { max = length } }  END{ if ( max == 0 ) { print 0 } else { print max + 1 } }'
          )
          pre_release_id_count="$((pre_release_id_count-2))"
        else
          debug "empty pre release ?"
          pre_release_id_count=0
        fi
        debug "pre_release_id_count ${pre_release_id_count}"
        local sort_args='-t.'
        for ((pre_release_id_index=1; pre_release_id_index<=pre_release_id_count; pre_release_id_index++))
        do
            chars="$(echo "$version_pre_releases" | awk -F '.' '{ print $'${pre_release_id_index}' }' | tr -d $'\n')"
            if [[ "$chars" =~ ^[0-9]*$ ]]
            then
                sort_key_type=n
            else
                sort_key_type=
            fi
            sort_args="$sort_args -k$pre_release_id_index,$pre_release_id_index$sort_key_type"
        done
        debug "sort_args ${sort_args}"

        if [[ -n  ${version_pre_releases} ]]; then
         echo "$version_pre_releases" | eval sort "${sort_args}" | awk '{ if (length == 0) { print "'${version_main}'" } else { print "'${version_main}'-"$1 } }' | tail -n 1
        else
          echo ${version_main}
        fi
    )

    debug "version_pre_release $version_pre_release"
    # Get the version with the build number
    if [[ -z "${version_pre_release}" ]]; then
          version="${version_main}"
    else
         version=$(echo "$tags" | grep "^${version_pre_release//./\\.}" | tail -n 1)
    fi

    if [[ "" == "${version}" ]]
    then
        return 1
    else
        echo "${version}"
    fi
}

version-major() {
    local new
    local pre_release=${1:+-$1}
    local build=${2:++$2}
    # shellcheck disable=SC2155
    local version=$(version-get)
    # shellcheck disable=SC2155
    local major=$(version-parse-major "${version}")
    if [[ "" == "$version" ]]
    then
        new=${VERSION_PREFIX}1.0.0${pre_release}${build}
    else
        new=${VERSION_PREFIX}$((major+1)).0.0${pre_release}${build}
    fi
    version-do "$new" "$version"
}

version-minor() {
   local new
    local pre_release=${1:+-$1}
    local build=${2:++$2}
    # shellcheck disable=SC2155
    local version=$(version-get)
    # shellcheck disable=SC2155
    local major=$(version-parse-major "${version}")
    # shellcheck disable=SC2155
    local minor=$(version-parse-minor "${version}")
    if [[ "" == "$version" ]]
    then
        new=${VERSION_PREFIX}0.1.0${pre_release}${build}
    else
        new=${VERSION_PREFIX}${major}.$((minor+1)).0${pre_release}${build}
    fi
    version-do "$new" "$version"
}

version-patch() {
    local new
    local pre_release=${1:+-$1}
    local build=${2:++$2}
   # shellcheck disable=SC2155
    local version=$(version-get)
    # shellcheck disable=SC2155
    local major=$(version-parse-major "${version}")
    # shellcheck disable=SC2155
    local minor=$(version-parse-minor "${version}")
    # shellcheck disable=SC2155
    local patch=$(version-parse-patch "${version}")
    if [[ "" == "$version" ]]
    then
        new=${VERSION_PREFIX}0.1.0${pre_release}${build}
    else
        new=${VERSION_PREFIX}${major}.${minor}.$((patch+1))${pre_release}${build}
    fi
    version-do "$new" "$version"
}

version-release() {
    local new version major minor patch
    new=${VERSION_PREFIX}0.1.0
    version=$(version-get)
    major=$(version-parse-major "${version}")
    minor=$(version-parse-minor "${version}")
    patch=$(version-parse-patch "${version}")
    if [[ -n "$version" ]]; then
        new=${VERSION_PREFIX}${major}.${minor}.${patch}
    fi

    version-do "$new" "$version"
}

version-pre-release() {
    local pre_release=$1
    local build=${2:++$2}
    # shellcheck disable=SC2155
    local version=$(version-get)
    # shellcheck disable=SC2155
    local major=$(version-parse-major "${version}")
    # shellcheck disable=SC2155
    local minor=$(version-parse-minor "${version}")
    # shellcheck disable=SC2155
    local patch=$(version-parse-patch "${version}")

    if [[ "" == "$version" ]]
    then
        local new=${VERSION_PREFIX}0.1.0-${pre_release}${build}
    else
        local new=${VERSION_PREFIX}${major}.${minor}.${patch}-${pre_release}${build}
    fi
    version-do "$new" "$version"
}

version-build() {
    local build=$1
    # shellcheck disable=SC2155
    local version=$(version-get)
    # shellcheck disable=SC2155
    local major=$(version-parse-major "${version}")
    # shellcheck disable=SC2155
    local minor=$(version-parse-minor "${version}")
    # shellcheck disable=SC2155
    local patch=$(version-parse-patch "${version}")
    # shellcheck disable=SC2155
    local pre_release=$(version-parse-pre-release "${version}")
    if [[ "" == "$version" ]]
    then
        local new=${VERSION_PREFIX}0.1.0${pre_release}+${build}
    else
        local new=${VERSION_PREFIX}${major}.${minor}.${patch}${pre_release}+${build}
    fi
    version-do "$new" "$version"
}

version-do() {
    local new="$1"
    local version="$2"
    local sign="${GIT_SIGN:-0}"
    local cmd="git tag"
    if [[ "$sign" == "1" ]]
    then
        cmd="$cmd -as -m $new"
    fi
    if [[ ${dryrun} == 1 ]]
    then
        echo "$new"
    elif plugin-run "$new" "$version"
    then
        ${cmd} "$new" && echo "$new"
    fi
}

########################################
# Run
########################################

# Set home
readonly DIR_HOME="${HOME}"

# Use XDG Base Directories if possible
# (see http://standards.freedesktop.org/basedir-spec/basedir-spec-latest.html)
DIR_CONF="${XDG_CONFIG_HOME:-${HOME}}/.git-semver"

# Set vars
DIR_ROOT="$(git rev-parse --show-toplevel 2> /dev/null)"

# Set (and load) user config
if [[ -f "${DIR_ROOT}/.git-semver" ]]
then
    FILE_CONF="${DIR_ROOT}/.git-semver"
    source "${FILE_CONF}"
elif [[ -f "${DIR_CONF}/config" ]]
then
    FILE_CONF="${DIR_CONF}/config"
    # shellcheck source=config.example
    source "${FILE_CONF}"
else
    # No existing config file was found; use default
    FILE_CONF="${DIR_HOME}/.git-semver/config"
fi

GIT_HASH="$(git rev-parse HEAD 2> /dev/null)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2> /dev/null)"

# Parse args
action=
build=
pre_release=
dryrun=0
while :
do
    case "$1" in
        -d)
            dryrun=1
            ;;
        --dryrun)
            dryrun=1
            ;;
        -b)
            build=$2
            shift
            validate-build "$build"
            ;;
        -p)
            pre_release=$2
            shift
            validate-pre-release "$pre_release"
            ;;
        -v1)
            v1=$2
            shift
            validate-version "$v1"
            ;;
        -v2)
            v2=$2
            shift
            validate-version "$v2"
            ;;
        ?*)
            action=$1
            ;;
        *)
            break
            ;;
    esac
    shift
done

case "$action" in
    get)
        version-get
        ;;
    major)
        version-major "$pre_release" "$build"
        ;;
    minor)
        version-minor "$pre_release" "$build"
        ;;
    patch|next)
        version-patch "$pre_release" "$build"
        ;;
    pre-release)
        [[ -n "$pre_release" ]] || usage
        version-pre-release "$pre_release" "$build"
        ;;
    build)
        [[ -n "$build" ]] || usage
        version-build "$build"
        ;;
    parse)
        version-parse
        ;;
    compare)
        version-compare ${v1} ${v2}
        ;;
    release)
        version-release
        ;;
    debug)
        plugin-debug
        ;;
    help)
        usage
        ;;
    *)
        usage
        ;;
esac
