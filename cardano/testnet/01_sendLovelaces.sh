#!/bin/bash

# Script is brought to you by ATADA_Stakepool, Telegram @atada_stakepool

#load variables from common.sh
#       socket          Path to the node.socket (also exports socket to CARDANO_NODE_SOCKET_PATH)
#       genesisfile     Path to the genesis.json
#       magicparam      TestnetMagic parameter
#       cardanocli      Path to the cardano-cli executable
#       cardanonode     Path to the cardano-node executable
. "$(dirname "$0")"/00_common.sh

if [ $# -ge 3 ]; then
			fromAddr="$(dirname $1)/$(basename $1 .addr)"; fromAddr=${fromAddr/#.\//};
			toAddr="$(dirname $2)/$(basename $2 .addr)"; toAddr=${toAddr/#.\//};
			lovelacesToSend="$3";
		 else
		 cat >&2 <<EOF
Usage:  $(basename $0) <From AddressName> <To AddressName or HASH> <Amount in lovelaces OR keyword ALL to send all lovelaces but keep your assets OR keyword ALLFUNDS to send all funds including Assets>
        [Opt: metadata.json/.cbor]
        [Opt: list of UTXOs to use, | is the separator]
        [Opt: Message comment, starting with "msg: ...", | is the separator]


Optional parameters:

- If you wanna attach a Transaction-Message like a short comment, invoice-number, etc with the transaction:
   You can just add one or more Messages in quotes starting with "msg: ..." as a parameter. Max. 64chars / Message
   "msg: This is a short comment for the transaction" ... that would be a one-liner comment
   "msg: This is a the first comment line|and that is the second one" ... that would be a two-liner comment, | is the separator !

- If you wanna attach a Metadata JSON:
   You can add a Metadata.json (Auxilierydata) filename as a parameter to send it alone with the transaction.
   There will be a simple basic check that the transaction-metadata.json file is valid.

- If you wanna attach a Metadata CBOR:
   You can add a Metadata.cbor (Auxilierydata) filename as a parameter to send it along with the transaction.
   Catalyst-Voting for example is done via the voting_metadata.cbor file.

- In rare cases you wanna define the exact UTXOs that should be used for sending Funds out:
   "UTXO1#Index" ... to specify one UTXO, must be in quotes "..."
   "UTXO1#Index|UTXO2#Index" ... to specify more UTXOs provide them with the | as separator, must be in quotes "..."

EOF
  exit 1; fi

#Check if Parameter 3 is a number or the keywords ALL or ALLFUNDS
if [[ ! "${lovelacesToSend^^}" == "ALL"  && ! "${lovelacesToSend^^}" == "ALLFUNDS"  && -z "${lovelacesToSend##*[!0-9]*}" ]]; then echo -e "\n\e[35mERROR - No amount of lovecase (or keyword ALL/ALLFUNDS) specified.\n\e[0m"; exit 1; fi

#Check all optional parameters about there types and set the corresponding variables
#Starting with the 4th parameter (index3) up to the last parameter
metafileParameter=""; metafile=""; filterForUTXO=""; transactionMessage="{}" #Setting defaults

paramCnt=$#;
#IFS=' ' read -ra allParameters <<< "${@}"   #old, because the split on spaces is not working with messages
allParameters=( "$@" )
for (( tmpCnt=3; tmpCnt<${paramCnt}; tmpCnt++ ))
 do
        paramValue=${allParameters[$tmpCnt]}
        #echo -n "${tmpCnt}: ${paramValue} -> "

        #Check if an additional metadata.json/.cbor was set as parameter (not a Message, not a UTXO#IDX, not empty, not a number)
        if [[ ! "${paramValue,,}" =~ ^msg:(.*)$ ]] && [[ ! "${paramValue}" =~ ^([[:xdigit:]]+#[[:digit:]]+(\|?)){1,}$ ]] && [[ ! ${paramValue} == "" ]] && [ -z "${paramValue##*[!0-9]*}" ]; then

             metafile="$(dirname ${paramValue})/$(basename $(basename ${paramValue} .json) .cbor)"; metafile=${metafile//.\//}
             if [ -f "${metafile}.json" ]; then metafile="${metafile}.json"
                #Do a simple basic check if the metadatum is in the 0..65535 range
                metadatum=$(jq -r "keys_unsorted[0]" ${metafile} 2> /dev/null)
                if [[ $? -ne 0 ]]; then echo "ERROR - '${metafile}' is not a valid JSON file"; exit 1; fi
                #Check if it is null, a number, lower then zero, higher then 65535, otherwise exit with an error
   		if [ "${metadatum}" == null ] || [ -z "${metadatum##*[!0-9]*}" ] || [ "${metadatum}" -lt 0 ] || [ "${metadatum}" -gt 65535 ]; then echo "ERROR - MetaDatum Value '${metadatum}' in '${metafile}' must be in the range of 0..65535!"; exit 1; fi
                metafileParameter="${metafileParameter}--metadata-json-file ${metafile} "; metafileList="${metafileList}${metafile} "
             elif [ -f "${metafile}.cbor" ]; then metafile="${metafile}.cbor"
                metafileParameter="${metafileParameter}--metadata-cbor-file ${metafile} "; metafileList="${metafileList}${metafile} "
	     else echo -e "The specified Metadata JSON/CBOR-File '${metafile}' does not exist. Fileextension must be '.json' or '.cbor' Please try again."; exit 1;
             fi

        #Check if an additional UTXO#IDX filter was set as parameter "hex#num(|)" at least 1 time, but can be more often}
        elif [[ "${paramValue}" =~ ^([[:xdigit:]]+#[[:digit:]]+(\|?)){1,}$ ]]; then filterForUTXO="${paramValue}";

	#Check it its a MessageComment. Adding it to the JSON array if the length is <= 64 chars
	elif [[ "${paramValue,,}" =~ ^msg:(.*)$ ]]; then #if the parameter starts with "msg:" then add it
		msgString=$(trimString "${paramValue:4}");

		#Split the messages within the parameter at the "|" char
		IFS='|' read -ra allMessages <<< "${msgString}"

		#Add each message to the transactionMessage JSON
		for (( tmpCnt2=0; tmpCnt2<${#allMessages[@]}; tmpCnt2++ ))
		do
			tmpMessage=${allMessages[tmpCnt2]}
                        if [[ $(byteLength "${tmpMessage}") -le 64 ]]; then
                                                transactionMessage=$( jq ".\"674\".msg += [ \"${tmpMessage}\" ]" <<< ${transactionMessage} 2> /dev/null);
                                                if [ $? -ne 0 ]; then echo -e "\n\e[35mMessage-Adding-ERROR: \"${tmpMessage}\" contain invalid chars for a JSON!\n\e[0m"; exit 1; fi
                        else echo -e "\n\e[35mMessage-Adding-ERROR: \"${tmpMessage}\" is too long, max. 64 bytes allowed, yours is $(byteLength "${tmpMessage}") bytes long!\n\e[0m"; exit 1;
			fi
		done


        fi #end of different parameters check

 done

#Check if toAddr file doesn not exists, make a dummy one in the temp directory and fill in the given parameter as the hash address
if [ ! -f "${toAddr}.addr" ]; then echo "$(basename ${toAddr})" > ${tempDir}/tempTo.addr; toAddr="${tempDir}/tempTo"; fi

if [ ! -f "${fromAddr}.addr" ]; then echo -e "\n\e[35mERROR - \"${fromAddr}.addr\" does not exist! Please create it first with script 03a or 02.\e[0m"; exit 1; fi
if ! [[ -f "${fromAddr}.skey" || -f "${fromAddr}.hwsfile" ]]; then echo -e "\n\e[35mERROR - \"${fromAddr}.skey/hwsfile\" does not exist! Please create it first with script 03a or 02.\e[0m"; exit 1; fi


#Check if there are transactionMessages, if so, save the messages to a xxx.transactionMessage.json temp-file and add it to the list
if [[ ! "${transactionMessage}" == "{}" ]]; then
        transactionMessageMetadataFile="${tempDir}/$(basename ${fromAddr}).transactionMessage.json";
        tmp=$( jq . <<< ${transactionMessage} 2> /dev/null)
        if [ $? -eq 0 ]; then echo "${tmp}" > ${transactionMessageMetadataFile}; metafileParameter="${metafileParameter}--metadata-json-file ${transactionMessageMetadataFile} "; #add it to the list of metadata.jsons to attach
                         else echo -e "\n\e[35mERROR - Additional Transaction Message-Metafile is not valid:\n\n$${transactionMessage}\n\nPlease check your added Message-Paramters.\n\e[0m"; exit 1; fi
fi

echo -e "\e[0mSending lovelaces from Address\e[32m ${fromAddr}.addr\e[0m to Address\e[32m ${toAddr}.addr\e[0m:"
echo


#get live values
currentTip=$(get_currentTip)
ttl=$(get_currentTTL)
currentEPOCH=$(get_currentEpoch)

echo -e "\e[0mCurrent Slot-Height:\e[32m ${currentTip} \e[0m(setting TTL[invalid_hereafter] to ${ttl})"
echo

sendFromAddr=$(cat ${fromAddr}.addr)
sendToAddr=$(cat ${toAddr}.addr)

check_address "${sendFromAddr}"
check_address "${sendToAddr}"

echo -e "\e[0mSource Address ${fromAddr}.addr:\e[32m ${sendFromAddr} \e[90m"
echo -e "\e[0mDestination Address ${toAddr}.addr:\e[32m ${sendToAddr} \e[90m"
echo

#
# Checking UTXO Data of the source address and gathering data about total lovelaces and total assets
#

        #Get UTX0 Data for the address. When in online mode of course from the node and the chain, in offlinemode from the transferFile
        if ${onlineMode}; then
                                utxo=$(${cardanocli} query utxo --address ${sendFromAddr} ${magicparam} ); checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi;
                                utxoJSON=$(generate_UTXO "${utxo}" "${sendFromAddr}")
                                #utxoJSON=$(${cardanocli} query utxo --address ${sendFromAddr} ${magicparam} --out-file /dev/stdout); checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi;
                          else
				readOfflineFile;	#Reads the offlinefile into the offlineJSON variable
                                utxoJSON=$(jq -r ".address.\"${sendFromAddr}\".utxoJSON" <<< ${offlineJSON})
                                if [[ "${utxoJSON}" == null ]]; then echo -e "\e[35mPayment-Address not included in the offline transferFile, please include it first online!\e[0m\n"; exit 1; fi
        fi

        #Only use UTXOs specied in the extra parameter if present
        if [[ ! "${filterForUTXO}" == "" ]]; then echo -e "\e[0mUTXO-Mode: \e[32mOnly using the UTXO with Hash ${filterForUTXO}\e[0m\n"; utxoJSON=$(filterFor_UTXO "${utxoJSON}" "${filterForUTXO}"); fi

	txcnt=$(jq length <<< ${utxoJSON}) #Get number of UTXO entries (Hash#Idx), this is also the number of --tx-in for the transaction
	if [[ ${txcnt} == 0 ]]; then echo -e "\e[35mNo funds on the Source Address!\e[0m\n"; exit 1; else echo -e "\e[32m${txcnt} UTXOs\e[0m found on the Source Address!\n"; fi

	#Calculating the total amount of lovelaces in all utxos on this address
        #totalLovelaces=$(jq '[.[].amount[0]] | add' <<< ${utxoJSON})
        totalLovelaces=0

        totalAssetsJSON="{}"; 	#Building a total JSON with the different assetstypes "policyIdHash.name", amount and name
        totalPolicyIDsJSON="{}"; #Holds the different PolicyIDs as values "policyIDHash", length is the amount of different policyIDs

	assetsOutString="";	#This will hold the String to append on the --tx-out if assets present or it will be empty

        #For each utxo entry, check the utxo#index and check if there are also any assets in that utxo#index
        #LEVEL 1 - different UTXOs
        for (( tmpCnt=0; tmpCnt<${txcnt}; tmpCnt++ ))
        do
        utxoHashIndex=$(jq -r "keys_unsorted[${tmpCnt}]" <<< ${utxoJSON})
        utxoAmount=$(jq -r ".\"${utxoHashIndex}\".value.lovelace" <<< ${utxoJSON})   #Lovelaces
        totalLovelaces=$(bc <<< "${totalLovelaces} + ${utxoAmount}" )
        echo -e "Hash#Index: ${utxoHashIndex}\tAmount: ${utxoAmount}"
        assetsJSON=$(jq -r ".\"${utxoHashIndex}\".value | del (.lovelace)" <<< ${utxoJSON}) #All values without the lovelaces entry
        assetsEntryCnt=$(jq length <<< ${assetsJSON})

        if [[ ${assetsEntryCnt} -gt 0 ]]; then
                        #LEVEL 2 - different policyIDs
                        for (( tmpCnt2=0; tmpCnt2<${assetsEntryCnt}; tmpCnt2++ ))
                        do
                        assetHash=$(jq -r "keys_unsorted[${tmpCnt2}]" <<< ${assetsJSON})  #assetHash = policyID
                        assetsNameCnt=$(jq ".\"${assetHash}\" | length" <<< ${assetsJSON})
                        totalPolicyIDsJSON=$( jq ". += {\"${assetHash}\": 1}" <<< ${totalPolicyIDsJSON})

                                #LEVEL 3 - different names under the same policyID
                                for (( tmpCnt3=0; tmpCnt3<${assetsNameCnt}; tmpCnt3++ ))
                                do
                                assetName=$(jq -r ".\"${assetHash}\" | keys_unsorted[${tmpCnt3}]" <<< ${assetsJSON})
                                assetAmount=$(jq -r ".\"${assetHash}\".\"${assetName}\"" <<< ${assetsJSON})
                                assetBech=$(convert_tokenName2BECH ${assetHash} ${assetName})
                                if [[ "${assetName}" == "" ]]; then point=""; else point="."; fi
                                oldValue=$(jq -r ".\"${assetHash}${point}${assetName}\".amount" <<< ${totalAssetsJSON})
                                newValue=$(bc <<< "${oldValue}+${assetAmount}")
                                totalAssetsJSON=$( jq ". += {\"${assetHash}${point}${assetName}\":{amount: \"${newValue}\", name: \"${assetName}\", bech: \"${assetBech}\"}}" <<< ${totalAssetsJSON})
                                echo -e "\e[90m                           Asset: ${assetBech}  Amount: ${assetAmount} ${assetName}\e[0m"
                                done
                        done

        fi
        txInString="${txInString} --tx-in ${utxoHashIndex}"
        done
        echo -e "\e[0m-----------------------------------------------------------------------------------------------------"
        echo -e "Total ADA on the Address:\e[32m  $(convertToADA ${totalLovelaces}) ADA / ${totalLovelaces} lovelaces \e[0m\n"
        totalPolicyIDsCnt=$(jq length <<< ${totalPolicyIDsJSON});
        totalAssetsCnt=$(jq length <<< ${totalAssetsJSON})

	#Get a sorted list of the AssetHashes into a separate Array
        #totalAssetsHASHsorted=$(jq "keys | sort_by( split(\".\")[1]|length) | sort_by( split(\".\")[0])" 2> /dev/null <<< ${totalAssetsJSON})

        if [[ ${totalAssetsCnt} -gt 0 ]]; then
                        echo -e "\e[32m${totalAssetsCnt} Asset-Type(s) / ${totalPolicyIDsCnt} different PolicyIDs\e[0m found on the Address!\n"
                        printf "\e[0m%-56s%11s    %16s %-44s  %7s  %s\n" "PolicyID:" "ASCII-Name:" "Total-Amount:" "Bech-Format:" "Ticker:" "Meta-Name:"
                        for (( tmpCnt=0; tmpCnt<${totalAssetsCnt}; tmpCnt++ ))
                        do
                        assetHashName=$(jq -r "keys[${tmpCnt}]" <<< ${totalAssetsJSON})
                        #assetHashName=$(jq -r ".[${tmpCnt}]" <<< ${totalAssetsHASHsorted})
                        assetAmount=$(jq -r ".\"${assetHashName}\".amount" <<< ${totalAssetsJSON})
                        assetName=$(jq -r ".\"${assetHashName}\".name" <<< ${totalAssetsJSON})
                        assetBech=$(jq -r ".\"${assetHashName}\".bech" <<< ${totalAssetsJSON})
                        assetHashHex="${assetHashName:0:56}$(convert_assetNameASCII2HEX ${assetName})"

                        if $queryTokenRegistry; then if $onlineMode; then metaResponse=$(curl -sL -m 20 "${tokenMetaServer}${assetHashHex}"); else metaResponse=$(jq -r ".tokenMetaServer.\"${assetHashHex}\"" <<< ${offlineJSON}); fi
                                metaAssetName=$(jq -r ".name.value | select (.!=null)" 2> /dev/null <<< ${metaResponse}); if [[ ! "${metaAssetName}" == "" ]]; then metaAssetName="${metaAssetName} "; fi
                                metaAssetTicker=$(jq -r ".ticker.value | select (.!=null)" 2> /dev/null <<< ${metaResponse})
                        fi

                        printf "\e[90m%-70s \e[32m%16s %44s  \e[90m%-7s  \e[36m%s\e[0m\n" "${assetHashName}" "${assetAmount}" "${assetBech}" "${metaAssetTicker}" "${metaAssetName}"
                        if [[ $(bc <<< "${assetAmount}>0") -eq 1 ]]; then assetsOutString+="+${assetAmount} ${assetHashName}"; fi #only include in the sendout if more than zero
                        done
        fi

echo

#There are metadata file attached, list them:
if [[ ! "${metafileList}" == "" ]]; then echo -e "\e[0mInclude Metadata-File(s):\e[32m ${metafileList}\e[0m\n"; fi

#There are transactionMessages attached, show the metadatafile:
if [[ ! "${transactionMessage}" == "{}" ]]; then echo -e "\e[0mInclude Transaction-Message-Metadata-File:\e[32m ${transactionMessageMetadataFile}\n\e[90m"; cat ${transactionMessageMetadataFile}; echo -e "\e[0m"; fi

#Read ProtocolParameters
if ${onlineMode}; then
			protocolParametersJSON=$(${cardanocli} query protocol-parameters ${magicparam} ); #onlinemode
		  else
			protocolParametersJSON=$(jq ".protocol.parameters" <<< ${offlineJSON}); #offlinemode
		  fi
checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi

#
# Depending on the input of lovelaces / keyword, set the right rxcnt (one receiver or two receivers)
#

case "${lovelacesToSend^^}" in

	"ALLFUNDS" )	#If keyword ALLFUNDS was used, send all lovelaces and all assets to the destination address
			rxcnt=1;;

	"ALL" )		#If keyword ALL was used, send all lovelaces to the destination address, but send back all the assets if available
			if [[ ${totalAssetsCnt} -gt 0 ]]; then
								rxcnt=2;	#assets on the address, they must be sent back to the source
							  else
								rxcnt=1;	#no assets on the address
							  fi;;

	* )		#If no keyword was used, its just the amount of lovelacesToSend
			rxcnt=2;;
esac

#Generate Dummy-TxBody file for fee calculation
txBodyFile="${tempDir}/dummy.txbody"
rm ${txBodyFile} 2> /dev/null
if [[ ${rxcnt} == 1 ]]; then  #Sending ALLFUNDS or sending ALL lovelaces and no assets on the address
                        ${cardanocli} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${sendToAddr}+0${assetsOutString}" --invalid-hereafter ${ttl} --fee 0 ${metafileParameter} --out-file ${txBodyFile}
			checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
                        else  #Sending chosen amount of lovelaces or ALL lovelaces but return the assets to the address
#                       echo -e "${cardanocli} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${sendToAddr}+0${assetsOutString}" --tx-out ${sendToAddr}+0 --invalid-hereafter ${ttl} --fee 0 ${metafileParameter} --out-file ${txBodyFile}"
                        ${cardanocli} transaction build-raw --mary-era ${txInString} --tx-out "${sendToAddr}+0${assetsOutString}" --tx-out ${sendToAddr}+0 --invalid-hereafter ${ttl} --fee 0 ${metafileParameter} --out-file ${txBodyFile}
			checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
	fi
fee=$(${cardanocli} transaction calculate-min-fee --tx-body-file ${txBodyFile} --protocol-params-file <(echo ${protocolParametersJSON}) --tx-in-count ${txcnt} --tx-out-count ${rxcnt} ${magicparam} --witness-count 1 --byron-witness-count 0 | awk '{ print $1 }')
checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi

minOutUTXO=$(calc_minOutUTXO "${protocolParametersJSON}" "${sendToAddr}+0${assetsOutString}")

echo -e "\e[0mMinimum Transaction Fee for ${txcnt}x TxIn & ${rxcnt}x TxOut: \e[32m $(convertToADA ${fee}) ADA / ${fee} lovelaces \e[90m"
echo -e "\e[0mMinimum UTXO value for a Transaction: \e[32m ${minOutUTXO} lovelaces \e[90m"
echo

#
# Depending on the input of lovelaces / keyword, set the right amount of lovelacesToSend, lovelacesToReturn and also check about sendinglimits like minOutUTXO for returning assets if available
#

case "${lovelacesToSend^^}" in

        "ALLFUNDS" )    #If keyword ALLFUNDS was used, send all lovelaces and all assets to the destination address - rxcnt=1
                        lovelacesToSend=$(( ${totalLovelaces} - ${fee} ))
			echo -e "\e[0mLovelaces to send to ${toAddr}.addr: \e[33m ${lovelacesToSend} lovelaces \e[90m"
			if [[ ${lovelacesToSend} -lt ${minOutUTXO} ]]; then echo -e "\e[35mNot enough funds on the source Addr! Minimum UTXO value is ${minOutUTXO} lovelaces.\e[0m"; exit 1; fi
			if [[ ${totalAssetsCnt} -gt 0 ]]; then	#assets are also send completly over, so display them
				echo -ne "\e[0m   Assets to send to ${toAddr}.addr: \e[33m "
				for (( tmpCnt=0; tmpCnt<${totalAssetsCnt}; tmpCnt++ ))
                        	do
                        	assetHashName=$(jq -r "keys[${tmpCnt}]" <<< ${totalAssetsJSON})
                        	assetAmount=$(jq -r ".\"${assetHashName}\".amount" <<< ${totalAssetsJSON})
                        	assetName=$(jq -r ".\"${assetHashName}\".name" <<< ${totalAssetsJSON})
                        	echo -ne "${assetAmount} ${assetName} / "
                        	done
				echo
			fi
			;;

        "ALL" )         #If keyword ALL was used, send all lovelaces to the destination address, but send back all the assets if available
                        if [[ ${totalAssetsCnt} -gt 0 ]]; then
                                                                #assets on the address, they must be sent back to the source address with the minOutUTXO amount of lovelaces, rxcnt=2
								lovelacesToSend=$(( ${totalLovelaces} - ${fee} - ${minOutUTXO} )) #so send less over to
								lovelacesToReturn=${minOutUTXO} #minimum amount to return all the assets to the source address
                                                                echo -e "\e[0mLovelaces to send to ${toAddr}.addr: \e[33m $(convertToADA ${lovelacesToSend}) ADA / ${lovelacesToSend} lovelaces \e[90m"
                                                                echo -e "\e[0mLovelaces to return to ${fromAddr}.addr: \e[32m $(convertToADA ${lovelacesToReturn}) ADA / ${lovelacesToReturn} lovelaces \e[90m (to preserve all the assets)"
                                                                if [[ ${lovelacesToSend} -lt ${minOutUTXO} ]]; then echo -e "\e[35mNot enough funds on the source Addr! Minimum UTXO value is ${minOutUTXO} lovelaces.\e[0m"; exit 1; fi
                                                          else
                                                                #no assets on the address, so just send over all the lovelaces, rxcnt=1
                        					lovelacesToSend=$(( ${totalLovelaces} - ${fee} ))
                        					echo -e "\e[0mLovelaces to send to ${toAddr}.addr: \e[33m $(convertToADA ${lovelacesToSend}) ADA / ${lovelacesToSend} lovelaces \e[90m"
								if [[ ${lovelacesToSend} -lt ${minOutUTXO} ]]; then echo -e "\e[35mNot enough funds on the source Addr! Minimum UTXO value is ${minOutUTXO} lovelaces.\e[0m"; exit 1; fi
                                                          fi;;

        * )             #If no keyword was used, its just the amount of lovelacesToSend to the destination address, rest will be returned to the source address, rxcnt=2
                        echo -e "\e[0mLovelaces to send to ${toAddr}.addr: \e[33m $(convertToADA ${lovelacesToSend}) ADA / ${lovelacesToSend} lovelaces \e[90m"
                        if [[ ${lovelacesToSend} -lt ${minOutUTXO} ]]; then echo -e "\e[35mNot enough lovelaces to send to the destination! Minimum UTXO value is ${minOutUTXO} lovelaces.\e[0m"; exit 1; fi
			lovelacesToReturn=$(( ${totalLovelaces} - ${fee} - ${lovelacesToSend} ))
                        echo -e "\e[0mLovelaces to return to ${fromAddr}.addr: \e[32m $(convertToADA ${lovelacesToReturn}) ADA / ${lovelacesToReturn} lovelaces \e[90m"
			minReturnUTXO=$(calc_minOutUTXO "${protocolParametersJSON}" "${sendFromAddr}+${lovelacesToReturn}${assetsOutString}")
                        if [[ ${lovelacesToReturn} -lt ${minReturnUTXO} ]]; then echo -e "\e[35mNot enough funds on the source Addr to return the rest! Minimum UTXO value needed is ${minReturnUTXO} lovelaces.\e[0m";
										if [[ ${lovelacesToSend} -ge ${totalLovelaces} ]]; then echo -e "\e[35mIf you wanna send out ALL your lovelaces, use the keyword ALL instead of the amount.\e[0m";fi
										exit 1; fi
			;;
esac

txBodyFile="${tempDir}/$(basename ${fromAddr}).txbody"
txFile="${tempDir}/$(basename ${fromAddr}).tx"

echo
echo -e "\e[0mBuilding the unsigned transaction body: \e[32m ${txBodyFile} \e[90m"
echo

#Building unsigned transaction body
rm ${txBodyFile} 2> /dev/null
if [[ ${rxcnt} == 1 ]]; then  #Sending ALL funds  (rxcnt=1)
			${cardanocli} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${sendToAddr}+${lovelacesToSend}${assetsOutString}" --invalid-hereafter ${ttl} --fee ${fee} ${metafileParameter} --out-file ${txBodyFile}
			checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
			else  #Sending chosen amount (rxcnt=2), return the rest(incl. assets)
			${cardanocli} transaction build-raw ${nodeEraParam} ${txInString} --tx-out ${sendToAddr}+${lovelacesToSend} --tx-out "${sendFromAddr}+${lovelacesToReturn}${assetsOutString}" --invalid-hereafter ${ttl} --fee ${fee} ${metafileParameter} --out-file ${txBodyFile}
			#echo -e "\n\n\n${cardanocli} transaction build-raw ${nodeEraParam} ${txInString} --tx-out ${sendToAddr}+${lovelacesToSend} --tx-out \"${sendFromAddr}+${lovelacesToReturn}${assetsOutString}\" --invalid-hereafter ${ttl} --fee ${fee} --out-file ${txBodyFile}\n\n\n"
			checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
fi

cat ${txBodyFile}
echo

echo -e "\e[0mSign the unsigned transaction body with the \e[32m${fromAddr}.skey\e[0m: \e[32m ${txFile}\e[0m"
echo

#Sign the unsigned transaction body with the SecureKey
rm ${txFile} 2> /dev/null

#If payment address is a hardware wallet, use the cardano-hw-cli for the signing
if [[ -f "${fromAddr}.hwsfile" ]]; then
        start_HwWallet; checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi

	#if rxcnt==2 that means that some funds are returned back to the hw-wallet and if its a staking address, we can hide the return
	#amount of lovelaces which could cause confusion. we have to add the --change-output-key-file parameters for payment and stake if
	#its a base address. this only works great for base addresses, otherwise a warning would pop up on the hw-wallet complaining about that
	#there are no rewards, tzz.
	hwWalletReturnStr=""
	if [[ ${rxcnt} == 2 ]]; then
					#but now we have to check if its a base address, in that case we also need to add the staking.hwsfile
					stakeFromAddr="$(basename ${fromAddr} .payment).staking"
					if [[ -f "${stakeFromAddr}.hwsfile" ]]; then hwWalletReturnStr="--change-output-key-file ${fromAddr}.hwsfile --change-output-key-file ${stakeFromAddr}.hwsfile"; fi

				fi

        tmp=$(${cardanohwcli} transaction sign --tx-body-file ${txBodyFile} --hw-signing-file ${fromAddr}.hwsfile ${hwWalletReturnStr} ${magicparam} --out-file ${txFile} 2> /dev/stdout)
        if [[ "${tmp^^}" =~ (ERROR|DISCONNECT) ]]; then echo -e "\e[35m${tmp}\e[0m\n"; exit 1; else echo -e "\e[32mDONE\e[0m\n"; fi
        checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
else
	${cardanocli} transaction sign --tx-body-file ${txBodyFile} --signing-key-file ${fromAddr}.skey ${magicparam} --out-file ${txFile}
	checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
fi

echo -ne "\e[90m"
cat ${txFile}
echo

if [ "${ENV_SKIP_PROMPT}" == "YES" ] || ask "\n\e[33mDoes this look good for you, continue ?" N; then
	echo
	if ${onlineMode}; then	#onlinesubmit
				echo -ne "\e[0mSubmitting the transaction via the node... "
				${cardanocli} transaction submit --tx-file ${txFile} ${magicparam}
				checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
				echo -e "\e[32mDONE\n"

                                #Show the TxID
                                txID=$(${cardanocli} transaction txid --tx-file ${txFile}); echo -e "\e[0m TxID is: \e[32m${txID}\e[0m"
                                checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi;
                                if [[ ${magicparam^^} =~ (MAINNET|1097911063) ]]; then echo -e "\e[0mTracking: \e[32m${transactionExplorer}${txID}\n\e[0m"; fi

			  else	#offlinestore
				txFileJSON=$(cat ${txFile} | jq .)
				offlineJSON=$( jq ".transactions += [ { date: \"$(date -R)\",
									type: \"Transaction\",
									era: \"$(jq -r .protocol.era <<< ${offlineJSON})\",
									fromAddr: \"${fromAddr}\",
									sendFromAddr: \"${sendFromAddr}\",
									toAddr: \"${toAddr}\",
									sendToAddr: \"${sendToAddr}\",
									txJSON: ${txFileJSON} } ]" <<< ${offlineJSON})
				#Write the new offileFile content
				offlineJSON=$( jq ".history += [ { date: \"$(date -R)\", action: \"signed utxo-transaction from '${fromAddr}' to '${toAddr}'\" } ]" <<< ${offlineJSON})
		                offlineJSON=$( jq ".general += {offlineCLI: \"${versionCLI}\" }" <<< ${offlineJSON})
				echo "${offlineJSON}" > ${offlineFile}
				#Readback the tx content and compare it to the current one
				readback=$(cat ${offlineFile} | jq -r ".transactions[-1].txJSON")
				if [[ "${txFileJSON}" == "${readback}" ]]; then
                                                        showOfflineFileInfo;
                                                        echo -e "\e[33mTransaction txJSON has been stored in the '$(basename ${offlineFile})'.\nYou can now transfer it to your online machine for execution.\e[0m\n";
                                                 else
                                                        echo -e "\e[35mERROR - Could not verify the written data in the '$(basename ${offlineFile})'. Retry again or generate a new '$(basename ${offlineFile})'.\e[0m\n";
        			fi

	fi

fi

echo -e "\e[0m\n"



