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
# fair init --ci empties an existing .fair/, data store included, while the
# registry keeps its records; keep what the workflow may already have set up
if [ ! -d "$WORKSPACE/.fair" ]; then fair init --ci; fi
if ! fair pull --local $WORKSPACE/examples/fdp/SEIRSconfig.yaml; then exit 1; fi
if ! fair run --local $WORKSPACE/examples/fdp/SEIRSconfig.yaml; then exit 1; fi

# The test command becomes the script of a fair run, so it must be quoted for
# the shell that will run it: sh everywhere but Windows, where it is cmd.exe,
# which knows nothing of backslash escapes - there an argument with a space or
# a quote is double-quoted, with inner quotes as \" for Julia's argument parser
if [ "$RUNNER_OS" = "Windows" ]; then
  TEST_SCRIPT=""
  for arg in "$@"; do
    case "$arg" in
      *[!A-Za-z0-9_./=@:-]*) arg="\"$(printf '%s' "$arg" | sed 's/"/\\"/g')\"" ;;
    esac
    TEST_SCRIPT="$TEST_SCRIPT $arg"
  done
else
  TEST_SCRIPT="$(printf ' %q' "$@")"
fi
echo Test: "$TEST_SCRIPT"
# Escape the sed delimiter, & and backslashes so the line lands unchanged
ESCAPED_SCRIPT=$(printf '%s\n' "$TEST_SCRIPT" | sed -e 's/[\,&]/\\&/g')
echo Escaped test: "$ESCAPED_SCRIPT"
sed -e "s,\$TEST_SCRIPT,$ESCAPED_SCRIPT," $TEST_DIR/pre_config.yaml > $TEST_DIR/config.yaml
cat $TEST_DIR/config.yaml
if ! fair run --local --debug $TEST_DIR/config.yaml; then exit 1; fi
rm -f $TEST_DIR/config.yaml

deactivate
