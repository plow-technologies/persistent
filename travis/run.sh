#!/usr/bin/env bash

set -euxo pipefail

ARGS="$ARGS --no-terminal --install-ghc"
stack $ARGS solver --update-config

if [ "$BACKEND" = "none" ]
then
    PACKAGES=$(stack --install-ghc query locals | grep '^ *path' | sed 's@^ *path:@@' | grep -v 'persistent-test' )
    exec stack $ARGS test --pedantic $PACKAGES
else
    if [ "$BACKEND" = "postgresql" ]
    then
        psql -c 'create database persistent;' -U postgres
    elif [ "$BACKEND" = "mysql" ]
    then
        mysql -e 'create database persistent;'
    fi

    cd persistent-test
    exec stack $ARGS test --pedantic --fast persistent-test --flag persistent-test:$BACKEND --exec persistent-test
fi
