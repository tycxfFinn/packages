#!/bin/sh
# dns based ad/abuse domain blocking
# written by Dirk Brenken (dev@brenken.org)

# This is free software, licensed under the GNU General Public License v3.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

# set initial defaults
#
LC_ALL=C
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
adb_ver="2.3.2"
adb_enabled=1
adb_debug=0
adb_backup=0
adb_backupdir="/mnt"
adb_whitelist="/etc/adblock/adblock.whitelist"
adb_whitelist_rset="\$1 ~/^([A-Za-z0-9_-]+\.){1,}[A-Za-z]+/{print tolower(\"^\"\$1\"\\\|[.]\"\$1)}"
adb_fetch="/usr/bin/wget"
adb_fetchparm="--no-config --quiet --no-cache --no-cookies --max-redirect=0 --timeout=10 --no-check-certificate -O"
adb_dnslist="dnsmasq unbound"
adb_dnsprefix="adb_list"

# f_envload: load adblock environment
#
f_envload()
{
    local dns_up cnt=0

    # source in system library
    #
    if [ -r "/lib/functions.sh" ]
    then
        . "/lib/functions.sh"
    else
        f_log "error" "system library not found"
    fi

    # set dns backend environment
    #
    while [ ${cnt} -le 10 ]
    do
        for dns in ${adb_dnslist}
        do
            dns_up="$(ubus -S call service list "{\"name\":\"${dns}\"}" | jsonfilter -l1 -e "@.${dns}.instances.*.running")"
            if [ "${dns_up}" = "true" ]
            then
                case "${dns}" in
                    dnsmasq)
                        adb_dns="dnsmasq"
                        adb_dnsdir="/tmp/dnsmasq.d"
                        adb_dnshidedir="${adb_dnsdir}/.adb_hidden"
                        adb_dnsformat="awk '{print \"local=/\"\$0\"/\"}'"
                        break 2
                        ;;
                    unbound)
                        adb_dns="unbound"
                        adb_dnsdir="/var/lib/unbound"
                        adb_dnshidedir="${adb_dnsdir}/.adb_hidden"
                        adb_dnsformat="awk '{print \"local-zone: \042\"\$0\"\042 static\"}'"
                        break 2
                        ;;
                esac
            fi
        done
        sleep 1
        cnt=$((cnt+1))
    done
    if [ -z "${adb_dns}" ]
    then
        f_log "error" "no active/supported DNS backend found"
    fi

    # parse global section by callback
    #
    config_cb()
    {
        local type="${1}"
        if [ "${type}" = "adblock" ]
        then
            option_cb()
            {
                local option="${1}"
                local value="${2}"
                eval "${option}=\"${value}\""
            }
        else
            reset_cb
        fi
    }

    # parse 'source' section
    #
    parse_config()
    {
        local value opt section="${1}" options="enabled adb_src adb_src_rset adb_src_cat"
        eval "adb_sources=\"${adb_sources} ${section}\""
        for opt in ${options}
        do
            config_get value "${section}" "${opt}"
            if [ -n "${value}" ]
            then
                eval "${opt}_${section}=\"${value}\""
            fi
        done
    }

    # load adblock config
    #
    config_load adblock
    config_foreach parse_config source
}

# f_envcheck: check/set environment prerequisites
#
f_envcheck()
{
    # check 'enabled' option
    #
    if [ ${adb_enabled} -ne 1 ]
    then
        if [ "$(ls -dA "${adb_dnsdir}/${adb_dnsprefix}"* >/dev/null 2>&1)" ]
        then
            f_rmdns
            f_dnsrestart
        fi
        f_log "info " "adblock is currently disabled, please set adb_enabled to '1' to use this service"
        exit 0
    fi

    # check fetch utility
    #
    if [ ! -x "${adb_fetch}" ] && [ "$(readlink -fn "/bin/wget")" = "/bin/uclient-fetch" ]
    then
        adb_fetch="/bin/uclient-fetch"
        adb_fetchparm="-q --timeout=10 --no-check-certificate -O"
    fi
    if [ -z "${adb_fetch}" ] || [ -z "${adb_fetchparm}" ] || [ ! -x "${adb_fetch}" ] || [ "$(readlink -fn "${adb_fetch}")" = "/bin/busybox" ]
    then
        f_log "error" "required download utility with ssl support not found, e.g. install full 'wget' package"
    fi

    # create dns hideout directory
    #
    if [ ! -d "${adb_dnshidedir}" ]
    then
        mkdir -p -m 660 "${adb_dnshidedir}"
        chown -R "${adb_dns}":"${adb_dns}" "${adb_dnshidedir}" 2>/dev/null
    else
        rm -f "${adb_dnshidedir}/${adb_dnsprefix}"*
    fi

    # create adblock temp file/directory
    #
    adb_tmpload="$(mktemp -tu)"
    adb_tmpfile="$(mktemp -tu)"
    adb_tmpdir="$(mktemp -p /tmp -d)"

    # prepare whitelist entries
    #
    if [ -s "${adb_whitelist}" ]
    then
        awk "${adb_whitelist_rset}" "${adb_whitelist}" > "${adb_tmpdir}/tmp.whitelist"
    fi
}

# f_rmtemp: remove temporary files & directories
#
f_rmtemp()
{
    if [ -d "${adb_tmpdir}" ]
    then
        rm -f "${adb_tmpload}"
        rm -f "${adb_tmpfile}"
        rm -rf "${adb_tmpdir}"
    fi
}

# f_rmdns: remove dns related files & directories
#
f_rmdns()
{
    if [ -n "${adb_dns}" ]
    then
        rm -f "${adb_dnsdir}/${adb_dnsprefix}"*
        rm -f "${adb_backupdir}/${adb_dnsprefix}"*.gz
        rm -rf "${adb_dnshidedir}"
    fi
    ubus call service delete "{\"name\":\"adblock_stats\",\"instances\":\"statistics\"}" 2>/dev/null
}

# f_dnsrestart: restart the dns backend
#
f_dnsrestart()
{
    local cnt=0

    "/etc/init.d/${adb_dns}" restart >/dev/null 2>&1
    while [ ${cnt} -le 10 ]
    do
        adb_dnsup="$(ubus -S call service list "{\"name\":\"${adb_dns}\"}" | jsonfilter -l1 -e "@.${adb_dns}.instances.*.running")"
        if [ "${adb_dnsup}" = "true" ]
        then
            return 0
        fi
        cnt=$((cnt+1))
        sleep 1
    done
}

# f_list: backup/restore/remove block lists
#
f_list()
{
    local mode="${1}" in_rc="${adb_rc}" cnt=0

    case "${mode}" in
        backup)
            cnt="$(wc -l < "${adb_tmpfile}")"
            if [ ${adb_backup} -eq 1 ] && [ -d "${adb_backupdir}" ]
            then
                gzip -cf "${adb_tmpfile}" > "${adb_backupdir}/${adb_dnsprefix}.${src_name}.gz"
                adb_rc=${?}
            fi
            ;;
        restore)
            if [ ${adb_backup} -eq 1 ] && [ -d "${adb_backupdir}" ]
            then
                rm -f "${adb_dnsdir}/${adb_dnsprefix}.${src_name}"
                if [ -f "${adb_backupdir}/${adb_dnsprefix}.${src_name}.gz" ]
                then
                    gunzip -cf "${adb_backupdir}/${adb_dnsprefix}.${src_name}.gz" > "${adb_tmpfile}"
                    adb_rc=${?}
                fi
            fi
            ;;
        remove)
            rm -f "${adb_dnsdir}/${adb_dnsprefix}.${src_name}"
            if [ -d "${adb_backupdir}" ]
            then
                rm -f "${adb_backupdir}/${adb_dnsprefix}.${src_name}.gz"
            fi
            adb_rc=${?}
            ;;
    esac
    f_log "debug" "name: ${src_name}, mode: ${mode}, count: ${cnt}, in_rc: ${in_rc}, out_rc: ${adb_rc}"
}

# f_switch: suspend/resume adblock processing
#
f_switch()
{
    if [ -d "${adb_dnshidedir}" ]
    then
        local source target status mode="${1}"
        local dns_active="$(find "${adb_dnsdir}" -maxdepth 1 -type f -name "${adb_dnsprefix}*" -print)"
        local dns_passive="$(find "${adb_dnshidedir}" -maxdepth 1 -type f -name "${adb_dnsprefix}*" -print)"

        if [ -n "${dns_active}" ] && [ "${mode}" = "suspend" ]
        then
            source="${adb_dnsdir}/${adb_dnsprefix}"
            target="${adb_dnshidedir}"
            status="suspended"
        elif [ -n "${dns_passive}" ] && [ "${mode}" = "resume" ]
        then
            source="${adb_dnshidedir}/${adb_dnsprefix}"
            target="${adb_dnsdir}"
            status="resumed"
        fi
        if [ -n "${status}" ]
        then
            mv -f "${source}"* "${target}"
            f_dnsrestart
            f_log "info " "adblock processing ${status}"
        fi
    fi
}

# f_query: query block lists for certain (sub-)domains
#
f_query()
{
    local search result cnt
    local domain="${1}"
    local tld="${domain#*.}"
    local dns_active="$(find "${adb_dnsdir}" -maxdepth 1 -type f -name "${adb_dnsprefix}*" -print)"

    if [ -z "${dns_active}" ]
    then
         printf "%s\n" "::: no active block lists found, please start adblock first"
    elif [ -z "${domain}" ] || [ "${domain}" = "${tld}" ]
    then
        printf "%s\n" "::: invalid domain input, please submit a specific (sub-)domain, e.g. 'www.abc.xyz'"
    else
        cd "${adb_dnsdir}"
        while [ "${domain}" != "${tld}" ]
        do
            search="${domain//./\.}"
            result="$(grep -Hm1 "[/\"\.]${search}[/\"]" "${adb_dnsprefix}"* | awk -F ':|=|/|\"' '{printf(" %-20s : %s\n",$1,$4)}')"
            printf "%s\n" "::: distinct results for domain '${domain}'"
            if [ -z "${result}" ]
            then
                printf "%s\n" " no match"
            else
                printf "%s\n" "${result}"
            fi
            domain="${tld}"
            tld="${domain#*.}"
        done
    fi
}

# f_log: write to syslog, exit on error
#
f_log()
{
    local class="${1}" log_msg="${2}"

    if [ -n "${log_msg}" ] && ([ "${class}" != "debug" ] || [ ${adb_debug} -eq 1 ])
    then
        logger -t "adblock-[${adb_ver}] ${class}" "${log_msg}"
        if [ "${class}" = "error" ]
        then
            logger -t "adblock-[${adb_ver}] ${class}" "Please check the online documentation 'https://github.com/openwrt/packages/blob/master/net/adblock/files/README.md'"
            f_rmtemp
            f_rmdns
            exit 255
        fi
    fi
}

# main function for block list processing
#
f_main()
{
    local enabled url cnt sum_cnt=0 mem_total=0
    local src_name src_rset shalla_archive list active_lists
    local sysver="$(ubus -S call system board | jsonfilter -e '@.release.description')"
    mem_total="$(awk '$1 ~ /^MemTotal/ {printf $2}' "/proc/meminfo" 2>/dev/null)"

    f_log "info " "start adblock processing ..."
    for src_name in ${adb_sources}
    do
        eval "enabled=\"\${enabled_${src_name}}\""
        eval "url=\"\${adb_src_${src_name}}\""
        eval "src_rset=\"\${adb_src_rset_${src_name}}\""
        adb_dnsfile="${adb_tmpdir}/${adb_dnsprefix}.${src_name}"
        > "${adb_tmpload}"
        > "${adb_tmpfile}"
        adb_rc=0

        # basic pre-checks
        #
        if [ "${enabled}" != "1" ] || [ -z "${url}" ] || [ -z "${src_rset}" ]
        then
            f_list remove
            continue
        fi

        # download block list
        #
        f_log "debug" "name: ${src_name}, enabled: ${enabled}, backup: ${adb_backup}, dns: ${adb_dns}, fetch: ${adb_fetch}, memory: ${mem_total}"
        if [ "${src_name}" = "blacklist" ]
        then
            cat "${url}" 2>/dev/null > "${adb_tmpload}"
            adb_rc=${?}
        elif [ "${src_name}" = "shalla" ]
        then
            shalla_archive="${adb_tmpdir}/shallalist.tar.gz"
            "${adb_fetch}" ${adb_fetchparm} "${shalla_archive}" "${url}" 2>/dev/null
            adb_rc=${?}
            if [ ${adb_rc} -eq 0 ]
            then
                for category in ${adb_src_cat_shalla}
                do
                    tar -xOzf "${shalla_archive}" BL/${category}/domains >> "${adb_tmpload}"
                    adb_rc=${?}
                    if [ ${adb_rc} -ne 0 ]
                    then
                        break
                    fi
                done
            fi
            rm -f "${shalla_archive}"
            rm -rf "${adb_tmpdir}/BL"
        else
            "${adb_fetch}" ${adb_fetchparm} "${adb_tmpload}" "${url}" 2>/dev/null
            adb_rc=${?}
        fi

        # check download result and prepare domain output (incl. list backup/restore)
        #
        if [ ${adb_rc} -eq 0 ] && [ -s "${adb_tmpload}" ]
        then
            awk "${src_rset}" "${adb_tmpload}" > "${adb_tmpfile}"
            if [ -s "${adb_tmpfile}" ]
            then
                f_list backup
            else
                f_list restore
            fi
        else
            f_list restore
        fi

        # remove whitelist domains, final list preparation
        #
        if [ ${adb_rc} -eq 0 ] && [ -s "${adb_tmpfile}" ]
        then
            if [ -s "${adb_tmpdir}/tmp.whitelist" ]
            then
                grep -vf "${adb_tmpdir}/tmp.whitelist" "${adb_tmpfile}" | sort -u | eval "${adb_dnsformat}" > "${adb_dnsfile}"
            else
                sort -u "${adb_tmpfile}" | eval "${adb_dnsformat}" > "${adb_dnsfile}"
            fi
            adb_rc=${?}
            if [ ${adb_rc} -ne 0 ]
            then
                f_list remove
            fi
        else
            f_list remove
        fi
    done

    # overall sort
    #
    for src_name in $(ls -dASr "${adb_tmpdir}/${adb_dnsprefix}"* 2>/dev/null)
    do
        if [ ${mem_total} -ge 64000 ]
        then
            if [ -s "${adb_tmpdir}/blocklist.overall" ]
            then
                sort "${adb_tmpdir}/blocklist.overall" "${adb_tmpdir}/blocklist.overall" "${src_name}" | uniq -u > "${adb_tmpdir}/tmp.blocklist"
                mv -f "${adb_tmpdir}/tmp.blocklist" "${src_name}"
            fi
            cat "${src_name}" >> "${adb_tmpdir}/blocklist.overall"
        fi
        cnt="$(wc -l < "${src_name}")"
        sum_cnt=$((sum_cnt + cnt))
        list="${src_name/*./}"
        if [ -z "${active_lists}" ]
        then
            active_lists="\"${list}\":\"${cnt}\""
        else
            active_lists="${active_lists},\"${list}\":\"${cnt}\""
        fi
    done

    # restart the dns backend and write statistics to procd service instance
    #
    mv -f "${adb_tmpdir}/${adb_dnsprefix}"* "${adb_dnsdir}" 2>/dev/null
    chown "${adb_dns}":"${adb_dns}" "${adb_dnsdir}/${adb_dnsprefix}"* 2>/dev/null
    f_rmtemp
    f_dnsrestart
    if [ "${adb_dnsup}" = "true" ]
    then
        f_log "info " "block lists with overall ${sum_cnt} domains loaded successfully (${sysver})"
        ubus call service set "{\"name\":\"adblock_stats\",
            \"instances\":{\"statistics\":{\"command\":[\"\"],
            \"data\":{\"active_lists\":[{${active_lists}}],
            \"adblock_version\":\"${adb_ver}\",
            \"blocked_domains\":\"${sum_cnt}\",
            \"dns_backend\":\"${adb_dns}\",
            \"last_rundate\":\"$(/bin/date "+%d.%m.%Y %H:%M:%S")\",
            \"system\":\"${sysver}\"}}}}"
        return 0
    fi
    f_log "error" "dns backend restart with active block lists failed (${sysver})"
}

# handle different adblock actions
#
if [ "${adb_procd}" = "true" ]
then
    f_envload
    case "${1}" in
        stop)
            f_rmtemp
            f_rmdns
            f_dnsrestart
            ;;
        restart)
            f_rmtemp
            f_rmdns
            f_envcheck
            f_main
            ;;
        suspend)
            f_switch suspend
            ;;
        resume)
            f_switch resume
            ;;
        query)
            f_query "${2}"
            ;;
        *)
            f_envcheck
            f_main
            ;;
    esac
fi
exit 0
