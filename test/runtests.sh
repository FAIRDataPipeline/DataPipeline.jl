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

echo source $WORKSPACE/.venv/$ACTIVATE_DIR/activate
echo fair registry install
echo fair registry start
echo fair init --ci
echo fair pull --debug ../examples/fdp/SEIRSconfig.yaml
echo fair run --debug --dirty ../examples/fdp/SEIRSconfig.yaml

TEST_SCRIPT=$@
echo sed -e "s,\$TEST_SCRIPT,$TEST_SCRIPT," $TEST_DIR/pre_config.yaml > $TEST_DIR/config.yaml
echo fair run --debug --dirty config.yaml
echo rm -f config.yaml
