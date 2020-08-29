#!/bin/bash -eu

# download plugins given on the command line
#
# FROM jenkins
# RUN install-plugins.sh docker-slaves github-branch-source
#
# Environment variables:
# REF: directory with preinstalled plugins. Default: /usr/share/jenkins/ref/plugins
# JENKINS_WAR: full path to the jenkins.war. Default: /usr/share/jenkins/jenkins.war
# JENKINS_UC: url of the Update Center. Default: ""
# JENKINS_UC_EXPERIMENTAL: url of the Experimental Update Center for experimental versions of plugins. Default: ""
# JENKINS_INCREMENTALS_REPO_MIRROR: url of the incrementals repo mirror. Default: ""
# JENKINS_UC_DOWNLOAD: download url of the Update Center. Default: JENKINS_UC/download
# CURL_OPTIONS When downloading the plugins with curl. Curl options. Default: -sSfL
# CURL_CONNECTION_TIMEOUT When downloading the plugins with curl. <seconds> Maximum time allowed for connection. Default: 20
# CURL_RETRY When downloading the plugins with curl. Retry request if transient problems occur. Default: 3
# CURL_RETRY_DELAY When downloading the plugins with curl. <seconds> Wait time between retries. Default: 0
# CURL_RETRY_MAX_TIME When downloading the plugins with curl. <seconds> Retry only within this period. Default: 60
# MAX_CONCURRENT_DOWNLOADS is the maximum number of concurrent downloads

set -o pipefail


JENKINS_WAR=${JENKINS_WAR:-/usr/share/jenkins/jenkins.war}

. /usr/local/bin/jenkins-support

REF_DIR="${REF}/plugins"
FAILED="$REF_DIR/failed-plugins.txt"

getLockFile() {
    printf '%s' "$REF_DIR/${1}.lock"
}

getArchiveFilename() {
    printf '%s' "$REF_DIR/${1}.jpi"
}

download() {
    local plugin originalPlugin version lock ignoreLockFile url
    plugin="$1"
    version="${2:-latest}"
    ignoreLockFile="${3:-}"
    url="${4:-}"
    lock="$(getLockFile "$plugin")"

    if [[ $ignoreLockFile ]] || mkdir "$lock" &>/dev/null; then
        if ! doDownload "$plugin" "$version" "$url"; then
            # some plugin don't follow the rules about artifact ID
            # typically: docker-plugin
            originalPlugin="$plugin"
            plugin="${plugin}-plugin"
            if ! doDownload "$plugin" "$version" "$url"; then
                echo "Failed to download plugin: $originalPlugin or $plugin" >&2
                echo "Not downloaded: ${originalPlugin}" >> "$FAILED"
                return 1
            fi
        fi

        if ! checkIntegrity "$plugin"; then
            echo "Downloaded file is not a valid ZIP: $(getArchiveFilename "$plugin")" >&2
            echo "Download integrity: ${plugin}" >> "$FAILED"
            return 1
        fi
    fi
}

doDownload() {
    local plugin version url jpi
    plugin="$1"
    version="$2"
    url="$3"
    jpi="$(getArchiveFilename "$plugin")"

    # If plugin already exists and is the same version do not download
    if test -f "$jpi" && unzip -p "$jpi" META-INF/MANIFEST.MF | tr -d '\r' | grep "^Plugin-Version: ${version}$" > /dev/null; then
        echo "Using provided plugin: $plugin"
        return 0
    fi

    if [[ -n $url ]] ; then
        echo "Will use url=$url"
    elif [[ "$version" == "latest" && -n "$JENKINS_UC_LATEST" ]]; then
        # If version-specific Update Center is available, which is the case for LTS versions,
        # use it to resolve latest versions.
        url="$JENKINS_UC_LATEST/latest/${plugin}.hpi"
    elif [[ "$version" == "experimental" && -n "$JENKINS_UC_EXPERIMENTAL" ]]; then
        # Download from the experimental update center
        url="$JENKINS_UC_EXPERIMENTAL/latest/${plugin}.hpi"
    elif [[ "$version" == incrementals* ]] ; then
        # Download from Incrementals repo: https://jenkins.io/blog/2018/05/15/incremental-deployment/
        # Example URL: https://repo.jenkins-ci.org/incrementals/org/jenkins-ci/plugins/workflow/workflow-support/2.19-rc289.d09828a05a74/workflow-support-2.19-rc289.d09828a05a74.hpi
        local groupId incrementalsVersion
        # add a trailing ; so the \n gets added to the end
        readarray -t "-d;" arrIN <<<"${version};";
        unset 'arrIN[-1]';
        groupId=${arrIN[1]}
        incrementalsVersion=${arrIN[2]}
        url="${JENKINS_INCREMENTALS_REPO_MIRROR}/$(echo "${groupId}" | tr '.' '/')/${plugin}/${incrementalsVersion}/${plugin}-${incrementalsVersion}.hpi"
    else
        JENKINS_UC_DOWNLOAD=${JENKINS_UC_DOWNLOAD:-"$JENKINS_UC/download"}
        url="$JENKINS_UC_DOWNLOAD/plugins/$plugin/$version/${plugin}.hpi"
    fi

    echo "Downloading plugin: $plugin from $url"
    # We actually want to allow variable value to be split into multiple options passed to curl.
    # This is needed to allow long options and any options that take value.
    # shellcheck disable=SC2086
    retry_command curl ${CURL_OPTIONS:--sSfL} --connect-timeout "${CURL_CONNECTION_TIMEOUT:-20}" --retry "${CURL_RETRY:-3}" --retry-delay "${CURL_RETRY_DELAY:-0}" --retry-max-time "${CURL_RETRY_MAX_TIME:-60}" "$url" -o "$jpi"
    return $?
}

checkIntegrity() {
    local plugin jpi
    plugin="$1"
    jpi="$(getArchiveFilename "$plugin")"

    unzip -t -qq "$jpi" >/dev/null
    return $?
}

bundledPlugins() {
    if [ -f "$JENKINS_WAR" ]
    then
        TEMP_PLUGIN_DIR=/tmp/plugintemp.$$
        for i in $(jar tf "$JENKINS_WAR" | grep -E '[^detached-]plugins.*\..pi' | sort)
        do
            rm -fr $TEMP_PLUGIN_DIR
            mkdir -p $TEMP_PLUGIN_DIR
            PLUGIN=$(basename "$i"|cut -f1 -d'.')
            (cd $TEMP_PLUGIN_DIR;jar xf "$JENKINS_WAR" "$i";jar xvf "$TEMP_PLUGIN_DIR/$i" META-INF/MANIFEST.MF >/dev/null 2>&1)
            VER=$(grep -E -i Plugin-Version "$TEMP_PLUGIN_DIR/META-INF/MANIFEST.MF"|cut -d: -f2|sed 's/ //')
            echo "$PLUGIN:$VER"
        done
        rm -fr $TEMP_PLUGIN_DIR
    else
        echo "war not found, installing all plugins: $JENKINS_WAR"
    fi
}

versionFromPlugin() {
    local plugin=$1
    if [[ $plugin =~ .*:.* ]]; then
        echo "${plugin##*:}"
    else
        echo "latest"
    fi

}

installedPlugins() {
    for f in "$REF_DIR"/*.jpi; do
        echo "$(basename "$f" | sed -e 's/\.jpi//'):$(get_plugin_version "$f")"
    done
}

jenkinsMajorMinorVersion() {
    if [[ -f "$JENKINS_WAR" ]]; then
        local version major minor
        version="$(java -jar "$JENKINS_WAR" --version)"
        major="$(echo "$version" | cut -d '.' -f 1)"
        minor="$(echo "$version" | cut -d '.' -f 2)"
        echo "$major.$minor"
    else
        echo ""
    fi
}

main() {
    local plugin jenkinsVersion
    local plugins=()

    mkdir -p "$REF_DIR" || exit 1
    rm -f "$FAILED"

    # Read plugins from stdin or from the command line arguments
    if [[ ($# -eq 0) ]]; then
        while read -r line || [ "$line" != "" ]; do
            # Remove leading/trailing spaces, comments, and empty lines
            plugin=$(echo "${line}" | tr -d '\r' | sed -e 's/^[ \t]*//g' -e 's/[ \t]*$//g' -e 's/[ \t]*#.*$//g' -e '/^[ \t]*$/d')

            # Avoid adding empty plugin into array
            if [ ${#plugin} -ne 0 ]; then
                plugins+=("${plugin}")
            fi
        done
    else
        plugins=("$@")
    fi

    # Create lockfile manually before first run to make sure any explicit version set is used.
    echo "Creating initial locks..."
    for plugin in "${plugins[@]}"; do
        mkdir "$(getLockFile "${plugin%%:*}")"
    done

    echo "Analyzing war $JENKINS_WAR..."
    bundledPlugins="$(bundledPlugins)"

    echo "Registering preinstalled plugins..."
    installedPlugins="$(installedPlugins)"

    # Check if there's a version-specific update center, which is the case for LTS versions
    jenkinsVersion="$(jenkinsMajorMinorVersion)"
    if curl -fsL -o /dev/null "$JENKINS_UC/$jenkinsVersion"; then
        JENKINS_UC_LATEST="$JENKINS_UC/$jenkinsVersion"
        echo "Using version-specific update center: $JENKINS_UC_LATEST..."
    else
        JENKINS_UC_LATEST=
    fi

    echo "Downloading plugins..."
    CONCURRENT_DOWNLOADS=0
    MAX_CONCURRENT_DOWNLOADS=${MAX_CONCURRENT_DOWNLOADS:-10}
    for plugin in "${plugins[@]}"; do
        local reg='^([^:]+):?([^:]+)?:?([^:]+)?:?(http.+)?'
        if [[ $plugin =~ $reg ]]; then
            local pluginId="${BASH_REMATCH[1]}"
            local version="${BASH_REMATCH[2]}"
            local lock="${BASH_REMATCH[3]}"
            local url="${BASH_REMATCH[4]}"
            download "$pluginId" "$version" "${lock:-true}" "${url}" &
            CONCURRENT_DOWNLOADS=$((CONCURRENT_DOWNLOADS + 1))
            if [ $CONCURRENT_DOWNLOADS -ge $MAX_CONCURRENT_DOWNLOADS ]
            then
                wait   # wait all background process to finish
                CONCURRENT_DOWNLOADS=0
            fi
        else
          echo "Skipping the line '${plugin}' as it does not look like a reference to a plugin"
        fi
    done
    wait

    echo
    echo "WAR bundled plugins:"
    echo "${bundledPlugins}"
    echo
    echo "Installed plugins:"
    installedPlugins

    if [[ -f $FAILED ]]; then
        echo "Some plugins failed to download!" "$(<"$FAILED")" >&2
        exit 1
    fi

    echo "Cleaning up locks"
    find "$REF_DIR" -regex ".*.lock" | while read -r filepath; do
        rm -r "$filepath"
    done

}

main "$@"