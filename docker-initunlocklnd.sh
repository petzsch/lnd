#!/bin/bash
set -e

echo "[initunlocklnd] Waiting 2 seconds for lnd..."
sleep 2

# ensure that lnd is up and running before proceeding
while
    CA_CERT="$LND_DATA/tls.cert"
    LND_WALLET_DIR="$LND_DATA/data/chain/$1/$2/"
    MACAROON_FILE="$LND_DATA/admin.macaroon"
    MACAROON_HEADER="r0ckstar:dev"
    if [ -f "$MACAROON_FILE" ]; then
        MACAROON_HEADER="Grpc-Metadata-macaroon:$(xxd -p -c 10000 "$MACAROON_FILE" | tr -d ' ')"
    fi

    STATUS_CODE=$(curl -s --cacert "$CA_CERT" -H $MACAROON_HEADER -o /dev/null -w "%{http_code}" $LND_REST_LISTEN_HOST/v1/getinfo)
    # if lnd is running it'll either return 200 if unlocked (noseedbackup=1) or 404 if it needs initialization/unlock
    if [ "$STATUS_CODE" == "200" ] || [ "$STATUS_CODE" == "404" ] ; then
        break
    else    
        echo "[initunlocklnd] LND still didn't start, got $STATUS_CODE status code back... waiting another 2 seconds..."
        sleep 2
    fi
do true; done

# read variables after we ensured that lnd is up
CA_CERT="$LND_DATA/tls.cert"
LND_WALLET_DIR="$LND_DATA/data/chain/$1/$2/"
MACAROON_FILE="$LND_DATA/admin.macaroon"
MACAROON_HEADER="r0ckstar:dev"
if [ -f "$MACAROON_FILE" ]; then
    MACAROON_HEADER="Grpc-Metadata-macaroon:$(xxd -p -c 10000 "$MACAROON_FILE" | tr -d ' ')"
fi

WALLET_FILE="$LND_WALLET_DIR/wallet.db"
LNDUNLOCK_FILE=${WALLET_FILE/wallet.db/walletunlock.json}
if [ -f "$WALLET_FILE" ]; then
    if [ ! -f "$LNDUNLOCK_FILE" ]; then
        echo "[initunlocklnd] WARNING: UNLOCK FILE DOESN'T EXIST! MIGRATE LEGACY INSTALLATION TO NEW VERSION ASAP"
    else
        echo "[initunlocklnd] Wallet and Unlock files are present... parsing wallet password and unlocking lnd"

        # parse wallet password from unlock file
        WALLETPASS=$(jq -c -r '.wallet_password' $LNDUNLOCK_FILE)
        # Nicolas deleted default password in some wallet unlock files, so we initializing default if password is empty
        [ "$WALLETPASS" == "" ] && WALLETPASS="hellorockstar"
        WALLETPASS_BASE64=$(echo $WALLETPASS|base64|tr -d '\n\r')

        # execute unlockwallet call
        curl -s --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" -d '{ "wallet_password":"'$WALLETPASS_BASE64'" }' $LND_REST_LISTEN_HOST/v1/unlockwallet
    fi

else
    echo "[initunlocklnd] Wallet file doesn't exist. Initializing LND instance with new autogenerated password and seed"

    # generate seed mnemonic   
    GENSEED_RESP=$(curl -s --cacert "$CA_CERT" -X GET -H $MACAROON_HEADER $LND_REST_LISTEN_HOST/v1/genseed)
    CIPHER_ARRAY_EXTRACTED=$(echo $GENSEED_RESP | jq -c -r '.cipher_seed_mnemonic')

    # using static default password per feedback, randomly generated password would still be stored in cleartext
    WALLETPASS="hellorockstar"

    # save all the the data to unlock file we'll use for future unlocks
    RESULTJSON='{"wallet_password":"'$WALLETPASS'", "cipher_seed_mnemonic":'$CIPHER_ARRAY_EXTRACTED'}'
    mkdir -p $LND_WALLET_DIR
    echo $RESULTJSON > $LNDUNLOCK_FILE

    # prepare initwallet call json with wallet password and chipher seed mnemonic
    WALLETPASS_BASE64=$(echo $WALLETPASS|base64|tr -d '\n\r')
    INITWALLET_REQ='{"wallet_password":"'$WALLETPASS_BASE64'", "cipher_seed_mnemonic":'$CIPHER_ARRAY_EXTRACTED'}'

    # execute initwallet call
    curl -s --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" -d "$INITWALLET_REQ" $LND_REST_LISTEN_HOST/v1/initwallet
fi


if [ ! -z "$LND_HOST_FOR_LOOP" ]; then
    echo "[initunlocklnd] Preparing to start Loop"

    if [[ $LND_ENVIRONMENT == "regtest" ]]; then
        echo "[initunlocklnd] Loop can't be started for regtest"
    elif [ -f "$MACAROON_FILE" ]; then
        sleep 10

        echo "[initunlocklnd] Starting Loop"
        ./bin/loopd --network=$2 --lnd.macaroonpath=$MACAROON_FILE --lnd.host=$LND_HOST_FOR_LOOP --restlisten=0.0.0.0:8081 &
    else
        echo "[initunlocklnd] Loop can't be started without MACAROON"
    fi
fi