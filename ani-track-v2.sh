#!/bin/bash
# shellcheck source=/dev/null
#
## VARS
version="0.1"
runas="root"
workdir="${XDG_STATE_HOME:-$HOME/.local/state}/ani-track"
ani_cli_hist="${XDG_STATE_HOME:-$HOME/.local/state}/ani-cli/ani-hsts"
tmpsearchf="${workdir}/search-tmp"
tmpinfof="${workdir}/info-tmp"
histfile="${workdir}/ani-track.hist"
wwwdir="${workdir}/tmp-www"
tmpredirect="${workdir}/redirectoutput"
secrets_file="${workdir}/.secrets"
backup_dir="${workdir}/backup"
anitrackdb="${workdir}/anidb.csv"
redirectPort="8080"
deftype="anime"                                     ## default type can be at the moment only anime. the api supports also manga
API_AUTH_ENDPOINT="https://myanimelist.net/v1/oauth2/"
API_ENDPOINT="https://api.myanimelist.net/v2"
BASE_URL="$API_ENDPOINT/${deftype}"
web_browser="firefox"
timeout=120
wspace='%20'                                        ## white space can be + or %20
defslimit="40"
maxlimit="1000"                                     ## max limit of the api for anime recomendations its 100 atm
nsfw="true"                                         ## needed for gray and black flagged anime like spy x famaly 2...
csvseparator="|"                                    ## ; does not work becuse of "steins;gate"
bckfheader="##ID${csvseparator}TITLE${csvseparator}NUM_EPISODES_WATCHED${csvseparator}STATUS${csvseparator}SCORE"
debug="false"                                       ## can be true/0 or false/1 | prints all history in output
force_update="false"                                ## updates episodes to my anime list eaven if it reduces the episodes

## check if not run as root 
if [ "$(whoami)" == "${runas}" ] ;then
    echo "script must not be runned as user $runas"
    exit 1
fi

## functions
manualPage() {
        printf "
%s version: $version

usage:
  %s [options] [query]
  %s [options] [query] [options]

Options:
  -[v]+ verbose levels
  -f    force

Example:
  %s -s demon slayer -l 10
  %s -s one piece -w 1045
  %s -s chainsaw -w ++
  %s -o shippu -f 4
  %s -U 
\n\n" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" 
}

die() {
    printf "\33[2K\r\033[1;31m%s\033[0m\n" "$*" >&2
    exit 1
}

dep_ch() {
    missingdep=""
    plural=""
    for dep; do
        if ! command -v "$dep" >/dev/null ; then
            if [ X"$missingdep" == "X" ] ;then
                missingdep="$dep"
            else
                plural="s"
                missingdep+=" $dep"
            fi
        fi
    done
    ## for missing dep print name and die
    if [ X"$missingdep" != "X" ] ;then
        die "Program${plural} \"$missingdep\" not found. Please install it."
    fi
}

create_secrets() {
    touch "$secrets_file" || die "could not create secrets file: touch $secrets_file"
    printf "client_id=\nclient_secret=\ncode_challanger=\nauthorisation_code=\nbearer_token=\nrefresh_token=\n" > "$secrets_file" 
    die "add your api client id and the secret in the $secrets_file and re-run the script"
}

create_challanger() {
    code_verifier="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 128)"
    sed -i "s/code_challanger.*/code_challanger=$code_verifier/" "$secrets_file" || die "could not update code_challanger in secrets file"
    echo "new code_challanger updated"
    source "$secrets_file"
}

get_auth_code() {
    touch "$tmpredirect"
    mkdir "$wwwdir"
    printf "<html>\n<body>\n<h1>Verification Succeeded!</h1>\n<p>Close this browser tab and you may now return to the shell.</p>\n</body>\n</html>\n" > "${wwwdir}"/index.html
    trap 'rm -rf -- "$wwwdir"' EXIT
    auth_url="${API_AUTH_ENDPOINT}authorize?response_type=code&client_id=${client_id}&code_challenge=${code_challanger}"
    python3 -m http.server -d "$wwwdir" $redirectPort > "$tmpredirect" 2>&1 &
    wserver_pid="$!"
    "$web_browser" "$auth_url" >/dev/null 2>&1
    echo -e "please authenticate in the web browser and press enter after allow it"
    read -r -t "$timeout" _
    unset _
    kill "$wserver_pid"
    check_www_srv="$(grep -i "Address already in use" "$tmpredirect")"
    if [ X"$check_www_srv" != X ] ;then 
        echo "$redirectPort port was already in use"
        die "please check with 'sudo netstat -tlpn || sudo ss -4 -tlpn' if there is a service on port $redirectPort"
    fi
    auth_code="$(grep GET "$tmpredirect" |awk '{print $(NF-3)}' |awk -F= '{print $NF}' |tail -1)"
    if [ X"$auth_code" == X ] || [ "$(wc -w <<< "$auth_code")" -ne 1 ] || [ "${#auth_code}" -lt 128 ] ; then 
        die "something went wrong... "
    fi
    sed -i "s/authorisation_code.*/authorisation_code=$auth_code/" "$secrets_file" || die "could not update authorisation_code in secrets file"
    source "$secrets_file"
    acc=1
}

get_bearer_token() {
    URL="${API_AUTH_ENDPOINT}token"
    DATA="client_id=${client_id}"
    DATA+="&client_secret=${client_secret}"
    DATA+="&code=${authorisation_code}"
    DATA+="&code_verifier=${code_challanger}"
    DATA+="&grant_type=authorization_code"

    if [ "$1" == "refresh" ] ;then
        data="client_id=${client_id}"
        data+="&client_secret=${client_secret}"
        data+="&grant_type=refresh_token"
        data+="&refresh_token=$refresh_token" 
    fi

    get_bt="$(curl -sfX POST "$URL" -d "$DATA")"

    bt="$(jq -r '.access_token' <<< "$get_bt" 2>/dev/null)"
    rt="$(jq -r '.refresh_token' <<< "$get_bt" 2>/dev/null)"
    
    if [ X"$bt" == X ] || [ X"$rt" == X ] || [ "${#bt}" -lt 64 ] || [ "${#rt}" -lt 64 ] ;then
        die "could not get a valid bearer token"
    fi
    sed -i "s/bearer_token.*/bearer_token=$bt/;s/refresh_token.*/refresh_token=$rt/" "$secrets_file" || die "could not update bearer token in secrets file"
    source "$secrets_file"
    [ "$1" != "refresh" ] && btc=1
}

verify_login() {
    check_login="$(curl -sfX GET -w "%{http_code}" -o /dev/null "${API_ENDPOINT}/users/@me" -H "Authorization: Bearer ${bearer_token}" )"
    login_user="$(curl -sfX GET "${API_ENDPOINT}/users/@me" -H "Authorization: Bearer ${bearer_token}" |jq -r '.name'  )"
}

histupdate() {
    dt=$(date "+%Y-%m-%d %H:%M:%S")
    histline="${dt} : $1"
    if [ "$debug" == "0" ] || [ "$debug" == "true" ] ;then
        tee -a "$histfile" <<< "$histline"
    else
       echo "$histline" >> "$histfile"
    fi
}

search_anime() {
    [ X"$slimit" == X ]&& slimit="$defslimit"
    ## prepare search querry: remove other options and double spaces etc
    searchQuerry="$(sed "s/[[:space:]]\+-s[[:space:]]+//;s/-s //;s/ -l[[:space:]]\+[0-9]\+//;s/-o[[:space:]]+//;s/-l[[:space:]]\+[0-9]\+//;s/[[:space:]]\+/ /g;s/[[:space:]]/$wspace/g" <<< "$2")"
    
    histupdate "SEARCH $(sed 's/[[:space:]]\+-s[[:space:]]+//;s/-s //;s/ -l[[:space:]]\+[0-9]\+//;s/-l[[:space:]]\+[0-9]\+//' <<< "$2")" 
    
    ## if search querry is empty or have double space then return
    if [ X"$searchQuerry" == "X" ] || [[ "$searchQuerry" =~ ^(%20)+$ && ! "$searchQuerry" =~ %20[^%]+%20 ]] ;then
        echo "search querry is empty or trash: $searchQuerry"
        return
    fi

    DATA="q=${searchQuerry}"
    DATA+="&limit=${slimit}"
    DATA+="$cnfsw"

    curl -s "${BASE_URL}?${DATA}" -H "Authorization: Bearer ${bearer_token}" | jq . > "${tmpsearchf}"
    ## if file is empty then die 
    [ ! -s "${tmpsearchf}" ] && die "search results are empty... something went wrong. search querry was: $searchQuerry"
    ## grep in temp file for bad request and die if found 
    [ "$(grep -o "bad_request" "${tmpsearchf}")" == "bad_request" ] && die "nothing found or bad request... try again"
    #result="$(awk '{$1="";print}' <<< "$(printf "%s" "$(jq -r '.data[] | .node | [.title] | join(",")' "${tmpsearchf}")" | awk '{n++ ;print NR, $0}' | sed 's/^[[:space:]]//' | nth "Select anime: ")")"
    malaniname="$(awk '{$1="";print}' <<< "$(printf "%s" "$(jq -r '.data[] | .node | [.title] | join(",")' "${tmpsearchf}")" | awk '{n++ ;print NR, $0}' | sed 's/^[[:space:]]//' | fzf --reverse --cycle --prompt "Search $2 with $1 episodes done: ")")"
    if [ X"$malaniname" == X ] ; then
        echo "nothing selected, start next one"
    else
        malaniname="${malaniname#"${malaniname%%[![:space:]]*}"}"
        aniid="$(jq --arg malaniname "$malaniname" '.data[] | .node | select(.title == $malaniname) | .id' "${tmpsearchf}")"
        aniline=("$aniid" "$2" "$1")
    fi
}

update_local_db() {
    for i in ${aniline[0]} ;do 
        if [ X"$i" != X ] ;then
            if grep -qE "^${aniline[0]}${csvseparator}${aniline[1]}" "$anitrackdb" ; then
                histupdate "SET on ${aniline[1]} with id ${aniline[0]} in local db episodes done from $ck_ldb_epdone to ${aniline[2]}"
                sed -i "s/^${aniline[0]}${csvseparator}${aniline[1]}.*$/${aniline[0]}${csvseparator}${aniline[1]}${csvseparator}${aniline[2]}/" "$anitrackdb" || die "could not update $anitrackdb"
            else
                histupdate "INSERT ${aniline[1]} with id ${aniline[0]} in local db. ${aniline[2]} episodes done"
                echo "${aniline[0]}${csvseparator}${aniline[1]}${csvseparator}${aniline[2]}" >> "$anitrackdb" || die "could not update $anitrackdb"
            fi
        fi
    done
    unset aniline
    unset ck_ldb_epdone
}

bck_anilist() {
    bckfile="${backup_dir}/anilist_bck_${login_user}-$(date +"%Y%m%d-%H%M")" 
    curl -s "${API_ENDPOINT}/users/@me/animelist?fields=list_status&limit=${maxlimit}${cnfsw}" -H "Authorization: Bearer ${bearer_token}" |jq -r --arg csvseparator "$csvseparator" '.data[] | "\(.node.id)ZZZZZ\(.node.title | sub("\""; ""; "g"))ZZZZZ\(.list_status.num_episodes_watched)ZZZZZ\(.list_status.status)ZZZZZ\(.list_status.score)" | gsub("ZZZZZ"; $csvseparator)' |sort > "${bckfile}_tmp"
    echo "$bckfheader" |cat - "${bckfile}_tmp" > "${bckfile}"
    rm -f "${bckfile}_tmp"
#    bckfiles=($(ls -1 "${backup_dir}/anilist_bck_${login_user}"* |grep "[0-9]$" |sort -r))
    mapfile -t bckfiles < <(find "${backup_dir}" -maxdepth 1 -type f -name "anilist_bck_${login_user}*" -regex '.*[0-9]+$' -printf "%p\n" | sort -r)
    if [ "$(wc -w <<< "${bckfiles[@]}")" -ge 2 ] ;then
        lastbckf="${bckfiles[2]}"
        if diff -q "$lastbckf" "$bckfile" >/dev/null 2>&1 ;then
            histupdate "no changes since last backup"
            rm -f "$bckfile"
            bckfile="$lastbckf"
        else
            histupdate "create backup of anilist to $bckfile"
        fi
    fi
} 

parse_ani-cli_hist() {
    sed -i '/^$/d' "$anitrackdb"
    while read -r ani; do
        aniname="$(cut -d ' ' -f 2- <<< "$ani")"
        epdone="$(cut -d ' ' -f 1 <<< "$ani")"
        ck_ldb="$(awk -F "$csvseparator" -v ani="$aniname" '{if($2==ani) print $2}' "$anitrackdb")"
        ck_ldb_epdone="$(awk -F "$csvseparator" -v ani="$aniname" '{if($2==ani) print $3}' "$anitrackdb")"
        ck_ldb_id="$(awk -F "$csvseparator" -v ani="$aniname" '{if($2==ani) print $1}' "$anitrackdb")"
        ## if anime is already in local db
        if [ "$ck_ldb" == "$aniname" ] && [ X"$ck_ldb_epdone" != "$epdone" ] ; then
            if [ "$epdone" != "$ck_ldb_epdone" ] ;then
                aniline=("${ck_ldb_id}" "${ck_ldb}" "${epdone}")
                update_local_db
            fi
        ## if anime is not in local db
        elif [ X"$ck_ldb" == X ] ; then #[[ "$ck_ldb" =~ " " ]] || [[ ! "$ck_ldb" =~ ^-?[0-9]+$ ]] || [[ ! "$ck_ldb" =~ $'\n' ]];then
            search_anime "$epdone" "$aniname"
            update_local_db
        ## if local db has 2 entrys to the same anime, print error and continue
        elif [[ "$ck_ldb" =~ " " ]] || [[ ! "$ck_ldb" =~ ^-?[0-9]+$ ]] || [[ ! "$ck_ldb" =~ $'\n' ]];then
            printf "%s" "error: $ani found twice or more in $anitrackdb\nplease check the $anitrackdb\n"
            histupdate "ERROR multiple enttrys found with name $aniname. please check $anitrackdb"
            continue
        fi
        unset ck_ldb
        unset ck_ldb_id
        unset ck_ldb_epdone
    done <<< "$(awk '{$2="";for (i = 1; i <= NF-2; i++) printf "%s ", $i; printf "\n"}' "$ani_cli_hist" |tr -cd '[:alnum:][:space:]\n ' |sed 's/[[:space:]]\+/ /g')"
}

update_remote_db() {
    unset DATA
    DATA=" -d num_watched_episodes=${2}"
    [ -n "$3" ] && DATA+=" -d status=${3}"
    [ -n "$4" ] && DATA+=" -d score=${4}"
## disable SC2086 on this line becuse of $DATA should not be in quotes. otherwise the anime can't be updated
# shellcheck disable=SC2086
    update_on_mal="$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${BASE_URL}/${1}/my_list_status" $DATA -H "Authorization: Bearer ${bearer_token}" --data-urlencode 'score=8')"
    if [ "$update_on_mal" != "200" ] ;then
        die "could not update anime with id $1 on mal"
    fi
}

restore_from_bck() {
    nrck='^[0-9]+$'
    restore_file="$1"
    [ ! -f "$restore_file" ] && die "restore file $restore_file not found"
    csvck="$(grep -Ev "^#" "$restore_file" |awk -F "$csvseparator" '{if(NF!=5) exit 1}' ;echo $?)"
    [ "$csvck" -ge 1 ] && die "restore file $restore_file does have more or less columns then it should have..."

    allids="$(grep -Ev "^#" "$restore_file" "$bckfile" |awk -F "$csvseparator" '{print $1}' |sort -u)"
    for i in $allids ;do
        id="$i"
        name="$(awk -F "$csvseparator" -v id="$id" '{if(id==$1)print $2}' "$bckfile" "$restore_file" |head -1 )"
        latestep="$(awk -F "$csvseparator" -v id="$id" '{if(id==$1)print $3}' "$bckfile")"
        lateststat="$(awk -F "$csvseparator" -v id="$id" '{if(id==$1)print $4}' "$bckfile")"
        latestscore="$(awk -F "$csvseparator" -v id="$id" '{if(id==$1)print $5}' "$bckfile")"
        bckep="$(awk -F "$csvseparator" -v id="$id" '{if(id==$1)print $3}' "$restore_file")"
        bckstat="$(awk -F "$csvseparator" -v id="$id" '{if(id==$1)print $4}' "$restore_file")"
        bckscore="$(awk -F "$csvseparator" -v id="$id" '{if(id==$1)print $5}' "$restore_file")"
    done
    

}

update_script() {
    die "not implemented yet."
}

compare_mal_to_ldb() {
    awk -F "$csvseparator" '{print $1}' "$anitrackdb"| while IFS= read -r i ;do 
        epdone_ldb="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $3}' "$anitrackdb")"
        epdone_rdb="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $3}' "$bckfile")"
        aniname="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $2}' "$anitrackdb")"
        if [ X"$epdone_rdb" != X ] ;then
            ## -gt only if epdone_ldb in not empty
            if [ "$epdone_ldb" -gt "$epdone_rdb" ] || [ "$force_update" == "true" ] ;then
                 echo "MAL update anime $aniname with id $i from $epdone_rdb to $epdone_ldb episodes done"
                 update_remote_db "$i" "$epdone_ldb"
            fi
        else
            echo "MAL add anime $aniname with id $i and $epdone_ldb episodes done"
            update_remote_db "$i" "$epdone_ldb"
        fi
    done
}

get_recomendations() {
    die "not implemented yet."
}

### main

## do set the vars in the .secrets file. only for shellcheck https://www.shellcheck.net/wiki/SC2154
authorisation_code="" ;client_secret="" ;refresh_token="" ;bearer_token="" ;client_id="" ;code_challanger=""

for i in "$@" ;do
    if [ "$i" == "-v" ] ;then
        debug="true"
    elif [[ "$i" =~ -[v]+ ]] ;then
        set -x
        debug="true"
        trap "set +x" EXIT
    fi
done

## if $@ == 'null|-h|--help' run manual and exit
#para="$(sed 's/[[:space:]]+//g' <<< "$@")"
for i in "$@" ;do
    if [[ "$i" == "-h" || "$i" == "--help" || "$i" == "--" || "$i" == "--h" ]] ; then
        manualPage
        exit 0
    fi
done 

echo "Checking dependencies..."
dep_ch "fzf" "curl" "sed" "grep" "jq" "python3" "$web_browser" ||true 
echo -e '\e[1A\e[K'

## create $workdir
if ! mkdir -p "$backup_dir" ;then
    die "error: clould not run mkdir -p $workdir"
fi

## create temp files and trap for cleanup
for i in "$tmpsearchf" "$tmpinfof" "$tmpredirect" ;do 
    touch "$i" || die "could not create temp file: touch $i"
done
trap 'rm -f -- "$tmpsearchf" "$tmpinfof" "$tmpredirect"' EXIT

## create secrets if not exists 
[ ! -s "$secrets_file" ] && create_secrets

## check if there is other stuff then vars in secrets file
check_secrets="$(grep -Ev '^([[:alpha:]_]+)=.*$|^([[:alpha:]_]+)=$|^[[:space:]]+|^$|^#' "$secrets_file")"

## source if $check_secrets is epmty
if [ -z "$check_secrets" ] ; then
    source "$secrets_file"
else
    die "check you're secrets file becuse it can contain commands. Please remove everything thats not vars"
fi

## die when api client id and secrets is epmty
if [ X"$client_id" == X ] || [ X"$client_secret" == X ] ;then
    die "client_id and/or client_secret are empty. please add it to $secrets_file"
fi

## die if ani-cli history is not found
if [ ! -f "$ani_cli_hist" ] || [ ! -r "$ani_cli_hist" ] ;then
    die "ani-cli history not found in $ani_cli_hist"
fi

## create $anitrackdb or die
if [ ! -f "$anitrackdb" ] || [ ! -r "$anitrackdb" ] ;then
    touch "$anitrackdb" || die "could not create $anitrackdb"
fi

if [ "$nsfw" == "true" ] || [ "$nsfw" == "0" ] ;then
    cnfsw="&nsfw=true"
else
    cnfsw=""
fi

## check if challanger, auth code or bearer token is present or run functions to create 
if [ X"$code_challanger" == X ] || [ X"$authorisation_code" == X ] || [ X"$bearer_token" == X ] ;then 
    create_challanger
    get_auth_code
    get_bearer_token
fi

verify_login

if [ X"$login_user" == X ] || [ "$check_login" != 200 ] ;then
    echo "login was not successfull"
    if [ X"$refresh_token" != X ] ;then
        echo "try to refresh the bearer token"
        get_bearer_token "refresh"
        verify_login
    fi
    if [ "$btc" != 1 ] || [ "$acc" != 1 ] || [ "$check_login" != 200 ]  ; then
        echo "recreate new bearer token"
        create_challanger
        get_auth_code
        get_bearer_token
        verify_login
    else
        die "could not login\nplease check you're api secrets"
    fi
fi

echo -e "login successfull\nhi $login_user"

bck_anilist
parse_ani-cli_hist

while getopts "fl:urUR:" opt ;do
    case $opt in
        f)
            force_update="true"
            ;;
        l)
            slimit="$(grep -Eo "[0-9]+" <<< "OPTARG$")"
            if [ "$slimit" != "0" ] || [ X"$slimit" == X ] ; then
                echo "set search limit: $slimit"
            elif [ "$slimit" -gt "$maxlimit" ]; then
                histupdate "ERROR search limit of the api is $maxlimit"
                defslimit="$maxlimit"
            else
                slimit="$defslimit"
            fi
            ;;
        u)
            compare_mal_to_ldb
            ;;
        r)
            maxlimit="${maxlimit:0:3}"
            get_recomendations
            ;;
        U)
            update_script
            ;;
        R)
            restore_from_bck "$OPTARG"
            ;;
        ?)
            manualPage
            die "ERROR: invalid option -$OPTARG"
            ;;
    esac
done
exit 0
