#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

search_and_replace_progress_bar(){
	local search=$1
	local replace=$2
	local input=$3
	echo "The database rename operation may take a while with huge files, please take a beer..."
	sed -i "/$search/{
s//$replace/g
w /dev/stdout
}" "$input" | pv > /dev/null
	return ${PIPESTATUS[1]}
}

gzip_progress(){
	local input_file=$1
	local compressed_file=$2
	cat "$input_file" | pv -ls $( wc -l "$input_file" ) | gzip -c -- > "$compressed_file"
	return ${PIPESTATUS[2]}
}

#@param string db_dump_path		file path of the gzipped sql
#@param string dbhost_to
#@param string dbuser_to
#@param string dbport_to
mysql_import() {
	local port
	if [ ! -z "$4" ]; then # if got a valid port add to the options
		port="-P $4"
	fi
	gzip -t $1 2>/dev/null # verify if is a compressed file
	if [ $? -eq 0 ]; then # "Compressed file"
		pv --progress --name 'DB Import in progress' -tea "$1" | zcat | mysql -h "$2" -u "$3" -p $port
	else # "Uncompressed file"
		pv --progress --name 'DB Import in progress' -tea "$1" | mysql -p -h "$2" -u "$3" $port
	fi
	return ${PIPESTATUS[2]}
}

#@param string dbhost_from
#@param string database_name_from
#@param string dbuser_from
#@param string dbhost_to
#@param string database_name_to
#@param string dbuser_to
#@param string no_data optional parameter that defines if should export only data structure
clonedb() {
	local dbhost_from=$1
	local database_name_from=$2 | sed 's/ *$//g' # N.B. avoid spaces that cause, unexpectedly, to be interpreted as a database name
	local dbuser_from=$3
	local dbhost_to=$4
	local database_name_to=$5
	local dbuser_to=$6
	local no_data=$7 | sed 's/ *$//g' # N.B. avoid spaces that cause, unexpectedly, to be interpreted as a database name
	local copyid='.clone.'
	local curtime
	curtime=$(date +%s)
	local dump_path=/tmp/"$database_name_from""$copyid""$curtime".sql
	local database_name_separator='__'
	local new_database_name=$database_name_from$database_name_separator$database_name_to
	#optional default SQL data to append (e.g. Dev INSERTs as default db initialization) ecc..
	local database_app_data=$DIR/dev.default_data.sql # TODO: parameterize this value
	
	local red=`tput setaf 1` #failure
	local green=`tput setaf 2` #success
	local yellow=`tput setaf 3` #warning

	echo "$(tput setaf 6)START DUMPING DATABASE PROCESS$(tput sgr 0)"
	echo "Please enter the password for the database source: $(tput bold)$database_name_from:$dbuser_from@$dbhost_from$(tput sgr 0)"
	
	mysqldump -h "$dbhost_from" $no_data -u "$dbuser_from" -p --databases $database_name_from --log-error=/tmp/clone_db.error.log --column-statistics=0 | pv -W >"$dump_path"
	
	if [ ${PIPESTATUS[0]} -eq 0 ]; then
		# SUCCESS CASE
		echo "${green}database dumped successfully in: $dump_path$(tput sgr 0)"
	else
		# ERROR CASE
		echo "
		${red}failed to dump the database: $dump_path$(tput sgr 0)
		"
		echo "
		ERRORS:"
		cat /tmp/clone_db.error.log
		echo "
		"
		echo "please check the error log for details: /tmp/clone_db.error.log"
		return 1
	fi

	if [[ $(ls "$dump_path" 2>/dev/null | wc -l) == 1 ]]; then

		#SUCCESS: dump path founded

		# 1. search and replace in the sql code the database name and append the user input value
		sed -i "s/$database_name_from/$new_database_name/g" "$dump_path"
		if [ $? -eq 0 ]; then
			echo "${green}database renamed successfully!$(tput sgr 0)"
		else
			echo "${red}failed to search and replace with the new $dbhost_from$(tput sgr 0)"
		fi

		# 2. optionally append DEV fresh install DB data, only if structure-only flag was set to true
		if [ "$no_data" == "" ]; then
			# TODO: move as an optional question
			echo "append the fresh install db data for DEV environment"
			cat "$database_app_data" >> "$dump_path"
		fi

		# 3. import the database
		echo "$(tput setaf 6)START IMPORTING NEW DATABASE PROCESS$(tput sgr 0)"
		echo "Please enter the password for the destination database: $(tput setab 7)$new_database_name:$dbuser_to@$dbhost_to$(tput sgr 0) - file: $dump_path"
		mysql_import "$dump_path" "$dbhost_to" "$dbuser_to" "$dbport_to"
		if [ $? -eq 0 ]; then
			echo "${green}database imported successfully!$(tput sgr 0)"
			return_code=0
		else
			echo "${red}failed to import the dump$(tput sgr 0)"
			return_code=1
		fi

	else
		#FAILURE - dump path not found
		echo "${red}Something wrong happened while dumping the database: $dump_path$(tput sgr 0)"
		return_code=1
	fi

	# 4. delete the temporary db
	unlink "$dump_path"
	if [ $? -eq 0 ]; then
		echo "${green}temporary file deleted successfully$(tput sgr 0)"
	else
		echo "${yellow}failed to delete the temporary file!$(tput sgr 0)"
	fi

	return $return_code

}

procedure_local() {
	local COUNTER
	local filepath
	local curtime
	local backup_path
	local copyid='.clone.'
	local curtime
	curtime=$(date +%s)
	local database_name_from
	local database_new_name_to

	read -r -p "Please enter the name of the source database. e.g.: mydatabase_name
DB name: " database_name_from

	read -r -p "Please enter the name of the cloned database that you want to add. This part of the name will be appended to the previous selected database name. e.g.: database_to_copy.new_database, mydatabase_name.phpunit, mydatabase_name.francisdrake, mydatabase_name.feature-frico, mydatabase_name.hotfix-change-column-data-size, ecc..
DB name: " database_new_name_to

	local database_name_separator='__'
	local new_database_name=$database_name_from$database_name_separator$database_new_name_to
	local dump_path=/tmp/"$database_name_from""$copyid""$curtime".sql

	local dbhost_to
	local dbuser_to
	local dbport_to
	local myoption

	# ask to the user were to import the database
	echo "IMPORT DB <TO> settings:"
	load_preset myoption
	IFS='|' read -r dbhost_to database_name_to dbuser_to dbport_to <<< "$myoption"
	echo "$dbhost_to|$database_name_to|$dbuser_to|$dbport_to"

	while true; do
	read -r -p "Summary of the connection data required.

DB HOST TO: $dbhost_to
DB USER TO: $dbuser_to
DB CLONE TO: ${database_name_from}__${database_new_name_to}
DB PORT TO: $dbport_to

Are this informations correct? Do you whish to continue(y/n)? " answer
		case ${answer:0:1} in
		y | Y)
			break
			;;
		n | N)
			echo "The script is terminated"
			exit 1
			;;
		*) echo "
PLEASE ANSWER YES OR NO.
			" ;;
		esac
	done

	COUNTER=0
	# ask for the database from informations
	# allow user to choose from a previous backup
	echo "choose from one of the following backups:"
	declare -a backup_options
	backup_path="$DIR/backup/" # TODO: parametrize this value
	while IFS='' read -r line; do backup_options+=("$line"); done < <(ls "$backup_path")
	# shellcheck disable=SC2045
	for f in $(ls "$DIR/backup/"); do
		echo "$COUNTER) $f"
		((COUNTER++))
	done
	# show options
	while true; do
		read -r -p "Please type the index of the listed element: " answer
		if [ "$answer" -lt ${#backup_options[@]} ]; then
			break
		else
			echo "Please enter a valid index!"
		fi
	done

	# prepare the choosed file and then make a tmp copy
	filepath=${backup_options[$answer]}
	curtime=$(date +%s)
	tempfile=/tmp/"$curtime".sql.gz
	cp "$backup_path""$filepath" "$tempfile"

	pv "$tempfile" | gunzip > "$dump_path" # added progress bar to decompress operation

	# search and replace in the sql code the database name and append the user input value
	#sed -i "s/$database_name_from/$new_database_name/g" "$dump_path"
	search_and_replace_progress_bar "$database_name_from" "$new_database_name" "$dump_path"
	sed -i '/^CHANGE/d' $dump_path # eventually remove master and slave refs

	if [ $? -eq 0 ]; then
		echo "database renamed successfully!"
	else
		echo "${red}failed to search and replace with the new $dbhost_from$(tput sgr 0)"
		exit 1
	fi

	# import the database
	echo "START IMPORTING NEW DATABASE PROCESS"
	echo "Please enter the password for the destination database: $dbuser_to@$dbhost_to - file: $dump_path"
	mysql_import "$dump_path" "$dbhost_to" "$dbuser_to" "$dbport_to"
	if [ $? -eq 0 ]; then
		echo "${green}database imported successfully!$(tput sgr 0)"
		return_code=0
	else
		echo "${red}failed to import the dump$(tput sgr 0)"
		return_code=1
	fi

	# elimino l'archivio
	unlink "$tempfile"
	unlink "$dump_path"

	return $return_code
}

#shows the preset file options and allow to add a new entry
#@param string|integer skip_preset_id optional, if specified skips from listing
#return string the selected option
function load_preset(){
	local __resultvar=$1 # global var that should be allocated at the end of the function
	local skip_preset_id=$2 # string with the preset that should be unset from the options
	local __myoption=''
	local COUNTER

	COUNTER=0
	presets="$DIR/dbpreset.conf" # preset configuration file
	delete=("$skip_preset_id") # array with item names that should be deleted from listing
	declare -a from_options # associative array with options

	# skip the first N+1 lines of comments
	while IFS=$'\n' read -r line; do from_options+=("$line"); done < <(tail -n +4 "$presets")
	from_options+=("Add new configuration") # add a custom option
	# remove the target element that should not be in the list
	for target in "${delete[@]}"; do
		for i in "${!from_options[@]}"; do
			if [[ ${from_options[i]} = "$target" ]]; then
		  		unset 'from_options[i]'
			fi
		done
	done

	# rebuild the array to fill the gaps of the previous delete operation
	for i in "${!from_options[@]}"; do
		new_array+=( "${from_options[i]}" )
	done
	from_options=("${new_array[@]}")
	unset new_array

	#printf '%s\n' "${from_options[@]}" #debug print array content
	for each in "${from_options[@]}"; do
		echo "$COUNTER) $each"
		((COUNTER++))
	done

	# user choose the connection
	while true; do
		read -r -p "Please type the index of the listed preset you want to use: " answer
		if [ "$answer" -lt ${#from_options[@]} ]; then
			break
		else
			echo "Please enter a valid index!"
		fi
	done

	# if the answer is new connection ask for the fresh settings
	echo "You choosed option: $answer"
	__myoption=${from_options[$answer]}
	if [ "${from_options[$answer]}" == "Add new configuration" ]; then
		read -r -p "Please enter the name of the HOST from which I should read the database schema: " dbhost_from
		read -r -p "Please enter the name of the master database that you want to copy: " database_name_from
		read -r -p "Please enter the USER with the read permissions on the database: " dbuser_from
		read -r -p "Please enter the port (leave empty for default 3306) database: " dbport_from
		# now write to the files the new settings
		__myoption="$dbhost_from|$database_name_from|$dbuser_from|$dbport_from"
		echo "$__myoption" >> $presets
	fi
	eval $__resultvar="'$__myoption'"
}

procedure_remote() {
	local presets
	local dbhost_from
	local database_name_from
	local dbuser_from
	local dbport_from
	local dbhost_to
	local database_name_to
	local dbuser_to
	local dbport_to

	echo "IMPORT DB <FROM> settings:"
	load_preset myoption1
	IFS='|' read -r dbhost_from database_name_from dbuser_from dbport_from <<< "$myoption1"
	echo "$dbhost_from|$database_name_from|$dbuser_from|$dbport_from"
	echo "IMPORT DB <TO> settings:"
	#load_preset myoption2 "$myoption1" # with the second parameter you can avoid the script to ask for that specific option
	load_preset myoption2
	IFS='|' read -r dbhost_to database_name_to dbuser_to dbport_to <<< "$myoption2"
	echo "$dbhost_to|$database_name_to|$dbuser_to|$dbport_to"
	read -r -p "Please enter the name of the cloned database that you want to add. This part of the name will be appended to the previous selected database name. e.g.: database_to_copy.new_database, mydatabase_name.phpunit, mydatabase_name.frice, mydatabase_name.feature-frico, mydatabase_name.hotfix-change-column-data-size, ecc..
DB name: " database_name_to
	while true; do
		read -r -p "Do you want to dump DB structure only(y/n)? " answer
		case ${answer:0:1} in
		y | Y)
			no_data="--no-data"
			no_data_verbose="dump structure only"
			;;
		n | N)
			no_data=""
			no_data_verbose="dump data + structure"
			;;
		*) echo "
PLEASE ANSWER YES OR NO.
			" ;;
		esac

		read -r -p "Summary of the connection data required.$(tput sgr 0)

DB HOST FROM: $(tput bold)$dbhost_from$(tput sgr 0)
DB USER FROM: $(tput bold)$dbuser_from$(tput sgr 0)
DB CLONE FROM: $(tput bold)$database_name_from$(tput sgr 0)
DB PORT FROM: $(tput bold)$dbport_from$(tput sgr 0)
Params: $(tput setaf 3)${no_data_verbose}$(tput sgr 0)
-------------------------
DB HOST TO: $(tput bold)$dbhost_to$(tput sgr 0)
DB USER TO: $(tput bold)$dbuser_to$(tput sgr 0)
DB CLONE TO: $(tput bold)${database_name_from}__${database_name_to}$(tput sgr 0)
DB PORT TO: $(tput bold)$dbport_to$(tput sgr 0)

Are this informations correct? Do you whish to continue(y/n)? " answer
		case ${answer:0:1} in
		y | Y)
			clonedb "$dbhost_from" "$database_name_from" "$dbuser_from" "$dbhost_to" "$database_name_to" "$dbuser_from" $no_data
			return $?
			;;
		n | N)
			echo "The script is terminated"
			exit 1
			;;
		*) echo "
PLEASE ANSWER YES OR NO.
			" ;;
		esac
	done
}

echo "------------------------------- INFO ---------------------------------"
echo "Description:	$(tput setab 7)Cloning a database schema and importing new application initialization data$(tput sgr 0)"
echo "Author:		    $(tput setab 4)Alessio Somma <alessiosomma@gmail.com>$(tput sgr 0)"
echo "----------------------------------------------------------------------"

red=`tput setaf 1`
green=`tput setaf 2`

while true; do
	read -r -p "This process is going to CREATE a new database clone. Do you wish to continue(y/n)? " answer
	case ${answer:0:1} in
	y | Y)
		while true; do
			read -r -p "Do you whish to clone from a previous full dumped database (0) or from a live database (1) ? " source_type
			case ${source_type:0:1} in
			0)
				echo "SOURCE: process to import database from a local dump file"
				break
				;;
			1)
				echo "SOURCE: process to import database from a remote mysqldump"
				break
				;;
			*)
				echo "PLEASE ANSWER 1 for \"import database from file source\" OR 2 for \"import database from a remote mysqldump\""
				;;
			esac
		done
		if [ "$source_type" -eq 1 ]; then
			procedure_remote
		else
			procedure_local
		fi
		;;
	n | N)
		exit 1
		;;
	*) echo "Please answer yes or no." ;;
	esac
	if [ $? -eq 0 ]; then
		echo "${green} The script ended SUCCESSFULLY$(tput sgr 0)"
		return_code=1
	else
		echo "${red} The script ended with ERRORS$(tput sgr 0)"
		return_code=0
	fi
	exit $?
done
