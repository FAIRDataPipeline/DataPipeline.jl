source ../.venv/$ACTIVATE_DIR/activate
fair registry install
fair registry start
fair init --ci
fair pull --debug ../examples/fdp/SEIRSconfig.yaml
fair run --debug --dirty ../examples/fdp/SEIRSconfig.yaml

value=$@
sed -e "s,\$PWD,$PWD," -e "s,\$TEST_SCRIPT,$value," pre_config.yaml > config.yaml
fair run --debug --dirty config.yaml
rm -f config.yaml
