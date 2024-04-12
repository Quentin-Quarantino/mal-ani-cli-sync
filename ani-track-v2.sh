#!/bin/sh
# shellcheck source=/dev/null

if [ "$USER" = "root" ]; then
    echo "script must not be run as root"
    exit 1
fi

## functions
manualPage() {
    echo "
usage:
    ${0##*/} [options]
    ${0##*/} [options] [argument] [options]

Options:
    -u       update MAL watchlist from ani-cli watchlist
    -r       get recommendations based on the MAL watchlist
    -s       get seasonal animes
    -l 0-9   set search limit. default is $defslimit (terminal height -3)
    -f       force update if it will reduce episode on MAL watchlist
    -U       update script
    -R file  restore MAL watchlist from backup
    -[v]+    verbose levels

Example:
    ${0##*/} -u
    ${0##*/} -r -l 80
    ${0##*/} -U 

${0##*/} version: $version
"
}

die() {
    printf "\33[2K\r\033[1;31m%s\033[0m\n" "$*" >&2
    exit 1
}

dep_ch() {
    missingdep=""
    plural=""
    for dep; do
        if ! command -v "$dep" >/dev/null; then
            if [ X"$missingdep" = "X" ]; then
                missingdep="$dep"
            else
                plural="s"
                missingdep="$missingdep $dep+"
            fi
        fi
    done
    ## for missing dep print name and die
    if [ X"$missingdep" != "X" ]; then
        die "Program${plural} \"$missingdep\" not found. Please install it."
    fi
}

create_secrets() {
    : >"$secrets_file" || die "could not create secrets file: touch $secrets_file"
    printf "client_id=\nclient_secret=\ncode_challanger=\nauthorisation_code=\nbearer_token=\nrefresh_token=\ntoken_date=\n" >"$secrets_file"
    die "add your api client id and the secret in the $secrets_file and re-run the script"
}

create_config() {
    : >"$configfile" || die "could not create config file: touch $configfile"
    # shellcheck disable=SC2016
    printf '## used web browser for authentification\n#web_browser="firefox"\n## port for web server to get the auth code from oauth2.0\n#redirectPort="8080"\n## login timeout in sec\n#timeout=120\n## default search limit \n#defslimit=$(($(tput lines) - 3))\n## needed for gray and black flagged anime like spy x famaly 2...\n#nsfw="true"\n## can be true/0 or false/1 | prints all history in output\n#debug="false"\n## updates episodes to my anime list eaven if it reduces the episodes\n#force_update="false"\n## bearer token and refresh token are 32 days valid.\n#daysbevorerefresh="26"' >"$configfile"
}

create_challanger() {
    code_verifier="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 128)"
    sed -i "s/code_challanger.*/code_challanger=$code_verifier/" "$secrets_file" || die "could not update code_challanger in secrets file"
    echo "new code_challanger updated"
    . "$secrets_file"
}

get_auth_code() {
    : >"$tmpredirect"
    mkdir "$wwwdir"
    printf "<html>\n<body>\n<h1>Verification Succeeded!</h1>\n<p>Close this browser tab and return to the shell.</p>\n</body>\n</html>\n" >"${wwwdir}"/index.html
    trap 'rm -rf -- "$wwwdir"' EXIT
    auth_url="${API_AUTH_ENDPOINT}authorize?response_type=code&client_id=${client_id}&code_challenge=${code_challanger}"
    python3 -m http.server -d "$wwwdir" "$redirectPort" >"$tmpredirect" 2>&1 &
    wserver_pid="$!"
    "$web_browser" "$auth_url" >/dev/null 2>&1
    printf "please authenticate in the web browser and press enter after allowing it\n"
    (
        sleep "$timeout"
        echo "timeout reached" >&2
        exit 1
    ) &
    read -r _
    kill "$!" >/dev/null 2>&1 || true
    unset _
    kill "$wserver_pid"
    check_www_srv="$(grep -i "Address already in use" "$tmpredirect")"
    if [ X"$check_www_srv" != X ]; then
        echo "$redirectPort port was already in use"
        die "please check with 'sudo netstat -tlpn || sudo ss -4 -tlpn' if there is a service on port $redirectPort or copy the code from the url and paste it in $secrets_file on the auth_code variable"
    fi
    auth_code="$(grep GET "$tmpredirect" | awk '{print $(NF-3)}' | awk -F= '{print $NF}' | tail -1)"
    auth_code_wc="$(echo "$auth_code" | wc -w)"
    if [ X"$auth_code" = X ] || [ "$auth_code_wc" -ne 1 ] || [ "${#auth_code}" -lt 128 ]; then
        die "something went wrong... "
    fi
    sed -i "s/authorisation_code.*/authorisation_code=$auth_code/" "$secrets_file" || die "could not update authorisation_code in secrets file"
    . "$secrets_file"
    acc=1
}

get_bearer_token() {
    URL="${API_AUTH_ENDPOINT}token"
    DATA="client_id=${client_id}"
    DATA="${DATA}&client_secret=${client_secret}"
    DATA="${DATA}&code=${authorisation_code}"
    DATA="${DATA}&code_verifier=${code_challanger}"
    DATA="${DATA}&grant_type=authorization_code"

    if [ "$1" = "refresh" ]; then
        DATA="client_id=${client_id}"
        DATA="${DATA}&client_secret=${client_secret}"
        DATA="${DATA}&grant_type=refresh_token"
        DATA="${DATA}&refresh_token=$refresh_token"
    fi

    get_bt="$(curl -sfX POST "$URL" -d "$DATA")"

    bt="$(echo "$get_bt" | jq -r '.access_token' 2>/dev/null)"
    rt="$(echo "$get_bt" | jq -r '.refresh_token' 2>/dev/null)"

    if [ X"$bt" = X ] || [ X"$rt" = X ] || [ "${#bt}" -lt 64 ] || [ "${#rt}" -lt 64 ]; then
        die "could not get a valid bearer token"
    fi
    sed -i "s/bearer_token.*/bearer_token=$bt/;s/refresh_token.*/refresh_token=$rt/;s/token_date.*/token_date=$current_date/" "$secrets_file" || die "could not update bearer token in secrets file"
    . "$secrets_file"
    [ "$1" != "refresh" ] && btc=1
}

verify_login() {
    check_login="$(curl -sfX GET -w "%{http_code}" -o /dev/null "${API_ENDPOINT}/users/@me" -H "Authorization: Bearer ${bearer_token}")"
    login_user="$(curl -sfX GET "${API_ENDPOINT}/users/@me" -H "Authorization: Bearer ${bearer_token}" | jq -r '.name')"
}

histupdate() {
    dt=$(date "+%Y-%m-%d %H:%M:%S")
    histline="${dt} : $1"
    if [ "$debug" = "0" ] || [ "$debug" = "true" ]; then
        echo "$histline" | tee -a "$histfile"
    else
        echo "$histline" >>"$histfile"
    fi
}

search_anime() {
    [ X"$slimit" = X ] && slimit="$defslimit"
    ## prepare search querry: remove other options and double spaces etc
    searchQuerry="$(echo "$2" | sed "s/[[:space:]]\+-s[[:space:]]+//;s/-s //;s/ -l[[:space:]]\+[0-9]\+//;s/-o[[:space:]]+//;s/-l[[:space:]]\+[0-9]\+//;s/[[:space:]]\+/ /g;s/[[:space:]]/%20/g")"
    histupdate "SEARCH $(echo "$2" | sed 's/[[:space:]]\+-s[[:space:]]+//;s/-s //;s/ -l[[:space:]]\+[0-9]\+//;s/-l[[:space:]]\+[0-9]\+//' || true)"
    ## if search querry is empty or have double space then return
    #if [ X"$searchQuerry" = "X" ] || [[ "$searchQuerry" =~ ^(%20)+$ && ! "$searchQuerry" =~ %20[^%]+%20 ]]; then
    if [ X"$searchQuerry" = X ] || echo "$searchQuerry" | grep -Eq '^%20+$' 2>/dev/null && ! echo "$searchQuerry" | grep -Eq '%20[^%]+%20' 2>/dev/null; then
        echo "search querry is empty or trash: $searchQuerry"
        return
    fi
    DATA="q=${searchQuerry}"
    DATA="${DATA}&limit=${slimit}"
    DATA="${DATA}${cnfsw}"
    curl -s "${BASE_URL}?${DATA}" -H "Authorization: Bearer ${bearer_token}" | jq . >"${tmpsearchf}"
    ## if file is empty then die
    [ ! -s "${tmpsearchf}" ] && die "search results are empty... something went wrong. search querry was: $searchQuerry"
    ## grep in temp file for bad request and die if found
    if grep -qo "bad_request" "${tmpsearchf}"; then
        die "nothing found or bad request... try again"
    fi
    malaniname="$(printf "%s" "$(jq -r '.data[] | .node | [.title] | join(",")' "${tmpsearchf}")" | awk '{n++ ;print NR, $0}' | sed 's/^[[:space:]]//' | fzf --reverse --cycle --prompt "Search $2 with $1 episodes done: " | awk '{$1="";print}' || true)"
    if [ X"$malaniname" = X ]; then
        echo "nothing selected, start next one"
    else
        malaniname="${malaniname#"${malaniname%%[![:space:]]*}"}"
        aniid="$(jq --arg malaniname "$malaniname" '.data[] | .node | select(.title == $malaniname) | .id' "${tmpsearchf}")"
        ck_ldb_id="${aniid}"
        ck_ldb="${2}"
        ck_ldb_epdone="${1}"
    fi
}

update_local_db() {
    ## $1 MAL id | $2 anime name | $3 episodes done
    if grep -q "^${1}${csvseparator}${2}" "$anitrackdb"; then
        histupdate "SET on ${2} with id ${1} in local db episodes done from $ck_ldb_epdone to ${3}"
        sed -i "s/^${1}${csvseparator}${2}.*$/${1}${csvseparator}${2}${csvseparator}${3}/" "$anitrackdb" || die "could not update $anitrackdb"
    else
        histupdate "INSERT ${2} with id ${1} in local db. ${3} episodes done"
        echo "${1}${csvseparator}${2}${csvseparator}${3}" >>"$anitrackdb" || die "could not update $anitrackdb"
    fi
    unset ck_ldb_epdone
}

bck_anilist() {
    bckfile="${backup_dir}/anilist_bck_${login_user}-$(date +"%Y%m%d-%H%M")"
    curl -s "${API_ENDPOINT}/users/@me/animelist?fields=list_status,num_episodes&limit=${maxlimit}${cnfsw}" -H "Authorization: Bearer ${bearer_token}" | jq -r --arg csvseparator "$csvseparator" '.data[] | "\(.node.id)ZZZZZ\(.node.title | sub("\""; ""; "g"))ZZZZZ\(.list_status.num_episodes_watched)ZZZZZ\(.list_status.status)ZZZZZ\(.list_status.score)ZZZZZ\(.node.num_episodes)" | gsub("ZZZZZ"; $csvseparator)' | sort >"${bckfile}_tmp"
    echo "$bckfheader" | cat - "${bckfile}_tmp" >"${bckfile}"
    rm -f "${bckfile}_tmp"
    bckfiles="$(find "${backup_dir}" -maxdepth 1 -type f -name "anilist_bck_${login_user}*" -regex '.*[0-9]+$' -printf "%p\n" | sort -r)"
    countbackups="$(echo "$bckfiles" | wc -w)"
    if [ "$countbackups" -ge 2 ]; then
        lastbckf="$(echo "$bckfiles" | sed -n '2 p')"
        if diff -q "$lastbckf" "$bckfile" >/dev/null 2>&1; then
            histupdate "no changes since last backup"
            rm -f "$bckfile"
            bckfile="$lastbckf"
        else
            histupdate "create backup of anilist to $bckfile"
        fi
    fi
}

parse_ani_cli_hist() {
    sed -i '/^$/d' "$anitrackdb"
    awk '{$2="";for (i = 1; i <= NF-2; i++) printf "%s ", $i; printf "\n"}' "$ani_cli_hist" | tr -cd '[:alnum:][:space:]\n ' | sed 's/[[:space:]]\+/ /g' | while read -r ani; do
        aniname="$(echo "$ani" | cut -d ' ' -f 2-)"
        epdone="$(echo "$ani" | cut -d ' ' -f 1)"
        ck_ldb="$(awk -F "$csvseparator" -v ani="$aniname" '{if($2==ani) print $2}' "$anitrackdb")"
        ck_ldb_epdone="$(awk -F "$csvseparator" -v ani="$aniname" '{if($2==ani) print $3}' "$anitrackdb")"
        ck_ldb_id="$(awk -F "$csvseparator" -v ani="$aniname" '{if($2==ani) print $1}' "$anitrackdb")"

        ## if anime is already in local db
        if [ "$ck_ldb" = "$aniname" ] && [ X"$ck_ldb_epdone" != "$epdone" ]; then
            if [ "$epdone" != "$ck_ldb_epdone" ]; then
                update_local_db "${ck_ldb_id}" "${ck_ldb}" "${epdone}"
            fi
        ## if anime is not in local db
        elif [ X"$ck_ldb" = X ]; then #[[ "$ck_ldb" =~ " " ]] || [[ ! "$ck_ldb" =~ ^-?[0-9]+$ ]] || [[ ! "$ck_ldb" =~ $'\n' ]];then
            search_anime "$epdone" "$aniname"
            update_local_db "${ck_ldb_id}" "${ck_ldb}" "${epdone}"
        ## if local db has 2 entrys to the same anime, print error and continue
        #elif [[ "$ck_ldb" =~ " " ]] || [[ ! "$ck_ldb" =~ ^-?[0-9]+$ ]] || [[ ! "$ck_ldb" =~ $'\n' ]];then
        #elif echo "$ck_ldb" | grep -q " " || ! echo "$ck_ldb" | grep -qE '^(-?[0-9]+)$' || ! echo "$ck_ldb" | grep -q $'\n'; then
        elif echo "$ck_ldb" | grep -q " " || ! echo "$ck_ldb" | grep -qE '^(-?[0-9]+)$' || ! printf '%s\n' "$ck_ldb" | grep -q '^'; then
            printf "%s" "error: $ani found twice or more in $anitrackdb\nplease check the $anitrackdb\n"
            histupdate "ERROR multiple enttrys found with name $aniname. please check $anitrackdb"
            continue
        fi
        unset ck_ldb
        unset ck_ldb_id
        unset ck_ldb_epdone
    done #<<< "$(awk '{$2="";for (i = 1; i <= NF-2; i++) printf "%s ", $i; printf "\n"}' "$ani_cli_hist" |tr -cd '[:alnum:][:space:]\n ' |sed 's/[[:space:]]\+/ /g')"
}

update_remote_db() {
    unset DATA
    DATA=" -d num_watched_episodes=${2}"
    [ -n "$3" ] && DATA="${DATA} -d status=${3}"
    [ -n "$4" ] && DATA="${DATA} -d score=${4}"
    ## disable SC2086 on this line becuse of $DATA should not be in quotes. otherwise the anime can't be updated
    # shellcheck disable=SC2086
    update_on_mal="$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${BASE_URL}/${1}/my_list_status" $DATA -H "Authorization: Bearer ${bearer_token}" --data-urlencode 'score=8')"
    if [ "$update_on_mal" != "200" ]; then
        die "could not update anime with id $1 on mal"
    fi
}

restore_from_bck() {
    restore_file="$1"
    [ ! -f "$restore_file" ] && die "restore file $restore_file not found"
    getbckcolnr="$(echo "$bckfheader" | grep -o "$csvseparator" | wc -l)"
    getbckcolnr=$((getbckcolnr + 1))
    csvck="$(
        grep -Ev "^#" "$restore_file" | awk -F "$csvseparator" -v colcount="$getbckcolnr" '{if(NF!=$colcount) exit 1}'
        echo $?
    )"
    [ "$csvck" -ge 1 ] && die "restore file $restore_file does have more or less columns then it should have..."
    ## get ids of animes who will be deleted
    toaddaniid="$(awk -F "$csvseparator" 'NR==FNR{a[$1];next}!($1 in a){print $1}' "$bckfile" "$restore_file")"
    ## get ids of animes that will be added
    todelaniid="$(awk -F "$csvseparator" 'NR==FNR{a[$1];next}!($1 in a){print $1}' "$restore_file" "$bckfile")"
    ## get ids of animes that changed
    tochaaniid="$(awk -F "$csvseparator" 'NR==FNR{a[$1,$3,$4,$5];next}!(($1,$3,$4,$5) in a){print $1}' "$bckfile" "$restore_file")"
    for i in $todelaniid; do
        animeep="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $2 "|" $3 }' "$bckfile")"
        echo "${animeep%|*} with id $i and ${animeep##*|} episodes done will be deleted"
    done
    for i in $toaddaniid; do
        animeep="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $2 "|" $3 }' "$restore_file")"
        echo "${animeep%|*} with id $i and ${animeep##*|} episodes done will be added"
    done
    for i in $tochaaniid; do
        for j in $todelaniid $toaddaniid; do
            if [ "$i" = "$j" ]; then
                skip="true"
            fi
        done
        if [ "$skip" != "true" ]; then
            name_restore="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $2}' "$restore_file")"
            ep_restore="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $3}' "$restore_file")"
            state_restore="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $4}' "$restore_file")"
            score_restore="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $5}' "$restore_file")"
            ep_now="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $3}' "$bckfile")"
            printf "%s\n" "${name_restore} with id $i change episode from ${ep_now} to ${ep_restore}. state ${state_restore} score ${score_restore}"
        fi
        skip=false
    done

    echo "do you want to restore to that state? (y/Y)"
    (
        sleep "$timeout"
        echo "timeout reached" >&2
        exit 1
    ) &
    read -r answer
    kill "$!" >/dev/null 2>&1 || true
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        for i in $toaddaniid $tochaaniid; do
            ep_restore="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $3}' "$restore_file")"
            state_restore="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $4}' "$restore_file")"
            score_restore="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $5}' "$restore_file")"
            update_remote_db "${i}" "${ep_restore}" "${state_restore}" "${score_restore}"
        done
        for i in $todelaniid; do
            update_on_mal="$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${BASE_URL}/${i}/my_list_status" -H "Authorization: Bearer ${bearer_token}")"
            if [ "$update_on_mal" != "200" ]; then
                die "could not delete anime with id $i on mal"
            fi
        done
    fi
}

update_script() {
    update="$(curl -s -A 'Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124' "$updateurl")" || die "could not get updates. check connectivity"
    update="$(printf "%s\n" "$update" | diff -u "$0" -)"
    if [ -z "$update" ]; then
        echo "script is up to date"
    else
        if printf "%s\n" "$update" | patch "$0" -; then
            echo "script updated"
        else
            die "could not update. check permissions"
        fi
    fi
    exit 0
}

compare_mal_to_ldb() {
    awk -F "$csvseparator" '{print $1}' "$anitrackdb" | while IFS= read -r i; do
        epdone_ldb="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $3}' "$anitrackdb")"
        epdone_rdb="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $3}' "$bckfile")"
        ep_max="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $6}' "$bckfile")"
        current_status="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $4}' "$bckfile")"
        aniname="$(awk -F "$csvseparator" -v id="$i" '{if(id==$1) print $2}' "$anitrackdb")"
        if [ X"$epdone_rdb" != X ]; then
            ## -gt only if epdone_ldb in not empty
            if [ "$epdone_ldb" -gt "$epdone_rdb" ] || [ "$force_update" = "true" ]; then
                if [ "$ep_max" = "$epdone_ldb" ]; then
                    echo "MAL update anime $aniname with id $i from $epdone_rdb to $epdone_ldb episodes done and set anime as completed"
                    update_remote_db "$i" "$epdone_ldb" "completed"
                elif [ "$current_status" = "plan_to_watch" ] && [ "$epdone_rdb" -ge 1 ]; then
                    echo "MAL update anime $aniname with id $i from $epdone_rdb to $epdone_ldb episodes done and set anime as watching"
                    update_remote_db "$i" "$epdone_ldb" "watching"
                else
                    echo "MAL update anime $aniname with id $i from $epdone_rdb to $epdone_ldb episodes done"
                    update_remote_db "$i" "$epdone_ldb"
                fi
            fi
        else
            if [ "$ep_max" = "$epdone_ldb" ]; then
                echo "MAL add anime $aniname with id $i and $epdone_ldb episodes done and set anime as completed"
                update_remote_db "$i" "$epdone_ldb" "completed"
            elif [ "$current_status" = "plan_to_watch" ] && [ "$epdone_rdb" -ge 1 ]; then
                echo "MAL update anime $aniname with id $i from $epdone_rdb to $epdone_ldb episodes done and set anime as watching"
                update_remote_db "$i" "$epdone_ldb" "watching"
            else
                echo "MAL add anime $aniname with id $i and $epdone_ldb episodes done"
                update_remote_db "$i" "$epdone_ldb"
            fi
        fi
    done
}

get_recomendations() {
    echo
    unset genre
    [ X"$slimit" = X ] && slimit="$defslimit"
    [ "$slimit" -gt "$maxrecomendlimit" ] && slimit="$maxrecomendlimit"
    DATA="limit=${slimit}"
    DATA="${DATA}&fields=id,title,alternative_titles,synopsis,genres,mean,reank,start_date,end_date,status"
    DATA="${DATA}${cnfsw}"
    curl -s "${BASE_URL}/suggestions?${DATA}" -H "Authorization: Bearer ${bearer_token}" | jq . >"${tmpsearchf}"
    while [ "$genre" != "exit" ] && [ "$anime" != "exit" ]; do
        genre="$({
            echo "all"
            jq -r '.data[] | .node | .genres[] | .name' "${tmpsearchf}" | sort -u
            echo "exit"
        } | awk '{ if (NR==1) print NR, $0; else print NR, $0 }' | fzf --reverse --cycle --prompt "select a genre for the recomendation: " | awk '{$1="";print}' | sed -e 's/^[[:space:]]*//' || true)"
        [ X"$genre" = X ] && die "no genre selected"
        if [ "$genre" = "all" ] && [ "$genre" != "exit" ]; then
            anime="$({
                jq -r '.data[] | .node | .title' "${tmpsearchf}"
                echo "exit"
            } | awk '{n++ ;print NR, $0}' | fzf --reverse --cycle --prompt "select a anime for more informations: " | awk '{$1="";print}' | sed -e 's/^[[:space:]]*//' || true)"
        fi
        if [ "$genre" != "all" ] && [ "$genre" != "exit" ]; then
            anime="$({
                jq -r --arg genre "$genre" '.data[] | select(.node.genres[].name == $genre) | .node | .title' "${tmpsearchf}"
                echo "exit"
            } | awk '{n++ ;print NR, $0}' | fzf --reverse --cycle --prompt "select a anime for more informations: " | awk '{$1="";print}' | sed -e 's/^[[:space:]]*//' || true)"
        fi
        if [ X"$anime" != X ] && [ "$genre" != "exit" ] && [ "$anime" != "exit" ]; then
            alttitles="$(jq -r --arg anime "$anime" '.data[] | select(.node.title == $anime) | .node | .alternative_titles | .synonyms[] ' "${tmpsearchf}" | paste -sd ', ')"
            animesynopsis="$(jq -r --arg anime "$anime" '.data[] | select(.node.title == $anime) | .node | .synopsis' "${tmpsearchf}")"
            animegenres="$(jq -r --arg anime "$anime" '.data[] | select(.node.title == $anime) | .node | .genres[] | .name ' "${tmpsearchf}" | paste -sd ', ')"
            animeranking="$(jq -r --arg anime "$anime" '.data[] | select(.node.title == $anime) | .node | .mean' "${tmpsearchf}")"
            startdate="$(jq -r --arg anime "$anime" '.data[] | select(.node.title == $anime) | .node | .start_date' "${tmpsearchf}")"
            enddate="$(jq -r --arg anime "$anime" '.data[] | select(.node.title == $anime) | .node | .end_date' "${tmpsearchf}")"
            animestatus="$(jq -r --arg anime "$anime" '.data[] | select(.node.title == $anime) | .node | .status' "${tmpsearchf}")"

            printf "\e[36mtitle:\e[0m %s\n" "$anime"
            printf "\e[36malternative titles:\e[0m %s\n" "$alttitles"
            printf "\e[36msynopsis:\e[0m %s\n\n" "$animesynopsis"
            printf "\e[36mgenres:\e[0m %s\n" "$animegenres"
            printf "\e[36mranking:\e[0m %.2f\n" "$animeranking"
            printf "\e[36mstart date:\e[0m %s\n" "$startdate"
            printf "\e[36mend date:\e[0m %s\n" "$enddate"
            printf "\e[36mstatus:\e[0m %s\n" "$animestatus"
            echo
            printf "a - add to MAL watchlist\nw - watch with ani-cli\nc/none - go back to the recomendations\nq - quit\n"
            (
                sleep "$timeout"
                echo "timeout reached" >&2
                exit 1
            ) &
            read -r answer
            kill "$!" >/dev/null 2>&1 || true
            case "$answer" in
                a)
                    genre="exit"
                    aniid="$(jq -r --arg anime "$anime" '.data[] | select(.node.title == $anime) | .node | .id' "${tmpsearchf}")"
                    echo "MAL add anime $anime with id $aniid and status 'plan to watch'"
                    update_remote_db "$aniid" "0" "plan_to_watch"
                    ;;
                w)
                    genre="exit"
                    ani_cli="$(command -v ani-cli 2>/dev/null)"
                    if [ X"$ani_cli" != X ]; then
                        # shellcheck disable=SC2086
                        exec $ani_cli $anime
                    else
                        die "ani-cli not found in \$PATH"
                    fi
                    ;;
                c | "")
                    echo
                    unset anime
                    unset genre
                    ;;
                q | *)
                    anime="exit"
                    ;;
            esac
        fi
    done
}

get_seasonal_animes() {
    die "not implemented yet."
}

## VARS
version="0.1"
workdir="${XDG_STATE_HOME:-$HOME/.local/state}/ani-track"
ani_cli_hist="${XDG_STATE_HOME:-$HOME/.local/state}/ani-cli/ani-hsts"
tmpsearchf="${workdir}/search-tmp"
tmpinfof="${workdir}/info-tmp"
histfile="${workdir}/ani-track.hist"
configfile="${workdir}/ani-track.conf"
wwwdir="${workdir}/tmp-www"
tmpredirect="${workdir}/redirectoutput"
secrets_file="${workdir}/.secrets"
backup_dir="${workdir}/backup"
anitrackdb="${workdir}/anidb.csv"
redirectPort="8080"
API_AUTH_ENDPOINT="https://myanimelist.net/v1/oauth2/"
API_ENDPOINT="https://api.myanimelist.net/v2"
BASE_URL="$API_ENDPOINT/anime"
web_browser="firefox"
timeout=120
defslimit=$(($(tput lines) - 3))
## max limit of the api for anime recomendations its 100 atm
maxlimit="1000"
maxrecomendlimit="100"
## needed for gray and black flagged anime like spy x famaly 2...
nsfw="true"
## ; does not work becuse of "steins;gate"
csvseparator="|"
bckfheader="##ID${csvseparator}TITLE${csvseparator}EPISODES_WATCHED${csvseparator}STATUS${csvseparator}SCORE${csvseparator}EPISODES"
## can be true/0 or false/1 | prints all history in output
debug="false"
## updates episodes to my anime list eaven if it reduces the episodes
force_update="false"
updateurl="https://raw.githubusercontent.com/Quentin-Quarantino/ani-track/main/ani-track-v2.sh"
current_date=$(date +%Y-%m-%d)
daysbevorerefresh="26"

### main

## do set the vars in the .secrets file. only for shellcheck https://www.shellcheck.net/wiki/SC2154
authorisation_code=""
client_secret=""
refresh_token=""
bearer_token=""
client_id=""
code_challanger=""
token_date=""

for i in "$@"; do
    if [ "$i" = "-v" ]; then
        debug="true"
    elif echo "$i" | grep -Eq -- '-[v]+'; then
        set -x
        debug="true"
        trap "set +x" EXIT
    elif [ "$i" = "-h" ] || [ "$i" = "--help" ]; then
        manualPage
        exit 0
    fi
done

echo "Checking dependencies..."
dep_ch "fzf" "curl" "sed" "grep" "jq" "python3" "${web_browser}" || true
printf '\033[1A\033[K'

## create $workdir
if ! mkdir -p "$backup_dir"; then
    die "error: clould not run mkdir -p $workdir"
fi

## create temp files and trap for cleanup
for i in "$tmpsearchf" "$tmpinfof" "$tmpredirect"; do
    : >"$i" || die "could not create temp file: touch $i"
done
trap 'rm -f -- "$tmpsearchf" "$tmpinfof" "$tmpredirect"' EXIT

## create secrets if not exists
[ ! -s "$secrets_file" ] && create_secrets
[ ! -s "$configfile" ] && create_config

## check if there is other stuff then vars in secrets file
check_secrets="$(grep -Ev '^([[:alpha:]_]+)=.*$|^([[:alpha:]_]+)=$|^[[:space:]]+|^$|^#' "$secrets_file")"
check_config="$(grep -Ev '^([[:alpha:]_]+)=.*$|^([[:alpha:]_]+)=$|^[[:space:]]+|^$|^#' "$configfile")"

## source if $check_secrets is epmty
if [ -z "$check_secrets" ]; then
    . "$secrets_file"
else
    die "check you're secrets file becuse it can contain commands. Please remove everything thats not vars"
fi

if [ -z "$check_config" ]; then
    . "$configfile"
else
    echo "config file contains commands. please remove it or create a issue on github"
fi

## die when api client id and secrets is epmty
if [ X"$client_id" = X ] || [ X"$client_secret" = X ]; then
    die "client_id and/or client_secret are empty. please add it to $secrets_file"
fi

## die if ani-cli history is not found
if [ ! -f "$ani_cli_hist" ] || [ ! -r "$ani_cli_hist" ]; then
    die "ani-cli history not found in $ani_cli_hist"
fi

## create $anitrackdb or die
if [ ! -f "$anitrackdb" ] || [ ! -r "$anitrackdb" ]; then
    : >"$anitrackdb" || die "could not create $anitrackdb"
fi

if [ "$nsfw" = "true" ] || [ "$nsfw" = "0" ]; then
    cnfsw="&nsfw=true"
else
    cnfsw=""
fi
difference_days=$((($(date -d "${current_date}" +%s) - $(date -d "${token_date}" +%s)) / 86400))

## check if challanger, auth code or bearer token is present or run functions to create
if [ X"$code_challanger" = X ] || [ X"$authorisation_code" = X ] || [ X"$bearer_token" = X ]; then
    create_challanger
    get_auth_code
    get_bearer_token
fi

verify_login

if [ X"$login_user" = X ] || [ "$check_login" != 200 ] || [ "$difference_days" -ge "$daysbevorerefresh" ]; then
    echo "login was not successfull or token is too old"
    if [ X"$refresh_token" != X ]; then
        echo "try to refresh the bearer token"
        get_bearer_token "refresh"
        verify_login
    fi
    if [ "$btc" != 1 ] && [ "$check_login" != 200 ] || [ "$acc" != 1 ] && [ "$check_login" != 200 ]; then
        echo "recreate new bearer token"
        create_challanger
        get_auth_code
        get_bearer_token
        verify_login
    elif [ "$btc" = 1 ] || [ "$acc" = 1 ]; then
        die "could not login\nplease check you're api secrets"
    fi
fi

printf "login successful\nhi %s\n" "$login_user"

bck_anilist
parse_ani_cli_hist

while getopts "fl:urUR:vs" opt; do
    case $opt in
        f)
            force_update="true"
            ;;
        l)
            slimit="$(echo "$OPTARG" | grep -Eo "[0-9]+")"
            if [ "$slimit" != "0" ] || [ X"$slimit" = X ]; then
                echo "set search limit: $slimit"
            elif [ "$slimit" -gt "$maxlimit" ] || [ "$defslimit" -gt "$maxlimit" ]; then
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
            get_recomendations
            ;;
        s)
            get_seasonal_animes
            ;;
        U)
            update_script
            ;;
        R)
            restore_from_bck "$OPTARG"
            ;;
        [v]*)
            true
            ;;
        ?)
            manualPage
            die "ERROR: invalid option -$OPTARG"
            ;;
        *)
            manualPage
            die "ERROR: invalid option -$OPTARG"
            ;;
    esac
done
exit 0
