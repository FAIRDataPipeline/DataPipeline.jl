#!/bin/bash

if [ "$WORKSPACE" = "" ]; then
  if echo $PWD | grep -qe "test$"; then
    export WORKSPACE=$PWD/..
    export TEST_DIR=$PWD
  else
    export WORKSPACE=. # Don't really know where the workspace is!
    export PWD=$WORKSPACE/test
  fi
fi

if [ "$ACTIVATE_DIR" = "" ]; then
  export ACTIVATE_DIR=bin
fi

source $WORKSPACE/.venv/$ACTIVATE_DIR/activate
fair registry install
fair registry start
fair init --ci
fair pull --debug $WORKSPACE/examples/fdp/SEIRSconfig.yaml
fair run --debug --dirty $WORKSPACE/examples/fdp/SEIRSconfig.yaml

TEST_SCRIPT=$@
sed -e "s,\$TEST_SCRIPT,$TEST_SCRIPT," $TEST_DIR/pre_config.yaml > $TEST_DIR/config.yaml
fair run --debug --dirty config.yaml
rm -f config.yaml
