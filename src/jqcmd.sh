__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
__base="$(basename ${__file} .sh)"

_jqArch="linux32"
if [[ $sys_bit == "x86_64" ]]; then
    _jqArch="linux64"
fi
_jqbin=${__dir}/../bin/jq-${_jqArch}
[[ -e $_jqbin && ! -x $_jqbin ]] && chmod 755 $_jqbin

if [[ ! -x $_jqbin ]]; then
    _red "jq not found"
    exit 1
fi

if ! ( command -v patch 2>&1>/dev/null  && command -v diff 2>&1>/dev/null) ; then
    _green "检测到没有patch命令，正在自动安装..."
    $cmd install -y patch diff
fi

if ! ( command -v patch 2>&1>/dev/null  && command -v diff 2>&1>/dev/null) ; then
    _red "diff/patch not found"
    exit 1
fi

_jq () {
    $_jqbin "$@" < /dev/stdin
}

TMP_ORIG_JSON=$(mktemp --suffix=.json)
TMP_UPDT_JSON=$(mktemp --suffix=.json)
CMPATCH=$(mktemp --suffix=.patch)

jq_gen_json() {
    sed '/ *\/\//d' $v2ray_server_config > $TMP_ORIG_JSON
}

jq_gen_jsonpatch() {
    jq_gen_json
    diff -u $TMP_ORIG_JSON $v2ray_server_config > $CMPATCH
}

jq_clear_tmp() {
    rm -f $TMP_ORIG_JSON $TMP_UPDT_JSON $CMPATCH
}

jq_vmess_adduser () {
    local uuid=$1
    local alterId=${2:-64}
    local email=${3:-${uuid:30}@233}
    local level=1
    local client='{"id":"'${uuid}'","level":'${level}',"alterId":'${alterId}',"email":"'${email}'"}'
    local len_inbounds=$(_jq '(.inbounds|length) - 1' $TMP_ORIG_JSON)
    local _IDX
    for  _IDX in $(seq 0 ${len_inbounds}); do
        if [[ $(_jq ".inbounds[${_IDX}].protocol" $TMP_ORIG_JSON) == '"vmess"' ]]; then
            break
        fi
    done

    if [[ $(_jq ".inbounds[${_IDX}].protocol" $TMP_ORIG_JSON) != '"vmess"' ]]; then
        _red "vmess not found"
        return 1
    fi

    _jq --tab ".inbounds[${_IDX}].settings.clients += [${client}]" $TMP_ORIG_JSON > $TMP_UPDT_JSON
}

jq_patchback () {
    if patch --ignore-whitespace $TMP_UPDT_JSON < $CMPATCH; then
        mv $v2ray_server_config "${v2ray_server_config}.bak.${RANDOM}"
        install -m 644 $TMP_UPDT_JSON $v2ray_server_config
    fi
}

jq_printvmess() {
    local ADDRESS=${1:-SERVER_IP}
    local _MAKPREFIX=${2:-233}
    local INPUT=$TMP_ORIG_JSON
    [[ -s $TMP_UPDT_JSON ]] && INPUT=$TMP_UPDT_JSON

    local INBS=$(_jq -c '.inbounds[] | select(.protocol == "vmess" )' $INPUT)
    for IN in $INBS; do
        # echo $IN | _jq
        local _TYPE="\"none\""
        local _HOST=\"\"
        local _PATH=\"\"
        local _TLS=\"\"
        local _NET=$(echo $IN | _jq '.streamSettings.network')
        local _PORT=$(echo $IN | _jq '.port')
        local _NETTRIM=${_NET//\"/}
        echo
        echo "--------------------------  Server: ${ADDRESS}:${_PORT}/${_NETTRIM}   --------------------------"
        echo
        case $_NETTRIM in
            kcp)
                _TYPE='.streamSettings.kcpSettings.header.type'
                ;;
            ws)
                _HOST='.streamSettings.wsSettings.headers.Host'
                _PATH='.streamSettings.wsSettings.path'
                ;;
            h2|http)
                _HOST='.streamSettings.httpSettings.host|join(,)'
                _PATH='.streamSettings.httpSettings.path'
                _TLS="tls"
                ;;
            tcp)
                _TYPE='if .streamSettings.tcpSettings.header.type then .streamSettings.tcpSettings.header.type else "none" end'
                ;;
        esac
        local CLTLEN=$(echo $IN | _jq '.settings.clients|length - 1')
        for CLINTIDX in $( seq 0 $CLTLEN ); do
            local EMAIL=$(echo $IN | _jq 'if .settings.clients['${CLINTIDX}'].email then .settings.clients['${CLINTIDX}'].email else "DEFAULT" end')
            local _ps="${_MAKPREFIX}${ADDRESS}/${_NETTRIM}"
            _green "${EMAIL//\"/} -- ${_ps}"
            echo "vmess://"$(echo $IN | _jq -c '{"v":"2","ps":"'${_ps}'","add":"'${ADDRESS}'","port":.port,"id":.settings.clients['${CLINTIDX}'].id,"aid":.settings.clients['${CLINTIDX}'].alterId,"net":.streamSettings.network,"type":'${_TYPE}',"host":'${_HOST}',"path":'${_PATH}',"tls":'${_TLS}'}' | base64 -w0)
            echo
        done
    done
}