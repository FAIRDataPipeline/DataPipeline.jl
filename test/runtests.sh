#!/bin/bash

if [ "$WORKSPACE" = "" ]; then
  if echo $PWD | grep -qe "test$"; then
    export WORKSPACE=$PWD/..
    export TEST_DIR=$PWD
  else
    export WORKSPACE=. # Don't really know where the workspace is!
    export TEST_DIR=$WORKSPACE/test
  fi
else
  export TEST_DIR=$WORKSPACE/test
fi

echo TEST_DIR: $TEST_DIR
echo WORKSPACE: $WORKSPACE

if [ "$ACTIVATE_DIR" = "" ]; then
  export ACTIVATE_DIR=bin
fi

source $WORKSPACE/.venv/$ACTIVATE_DIR/activate
fair registry install
fair registry start
fair init --ci
if ! fair pull --local $WORKSPACE/examples/fdp/SEIRSconfig.yaml; then exit 1; fi
if ! fair run --dirty --local $WORKSPACE/examples/fdp/SEIRSconfig.yaml; then exit 1; fi

TEST_SCRIPT="$(printf ' %q' "$@")"
echo Test: "$TEST_SCRIPT"
ESCAPED_SCRIPT=$(printf '%s\n' "$TEST_SCRIPT" | sed -e 's/[\,&]/\\&/g')
if [ "$RUNNER_OS" = "Windows" ]; then
  ESCAPED_SCRIPT=$(printf '%s\n' "$ESCAPED_SCRIPT" | sed sed -e 's/\\\[/[/g' -e 's/\\]/]/g')
fi
echo Escaped test: "$ESCAPED_SCRIPT"
sed -e "s,\$TEST_SCRIPT,$ESCAPED_SCRIPT," $TEST_DIR/pre_config.yaml > $TEST_DIR/config.yaml
cat $TEST_DIR/config.yaml
if ! fair run --dirty --local --debug $TEST_DIR/config.yaml; then exit 1; fi
rm -f $TEST_DIR/config.yaml

deactivate
