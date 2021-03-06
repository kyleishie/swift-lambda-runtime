# Example settings
EXAMPLE_LAMBDA=SquareNumber
EXAMPLE_EXECUTABLE=$(EXAMPLE_LAMBDA)
EXAMPLE_PROJECT_PATH=Examples/$(EXAMPLE_LAMBDA)
LAMBDA_ZIP=$(EXAMPLE_PROJECT_PATH)/lambda.zip

SWIFT_DOCKER_IMAGE=fabianfett/amazonlinux-swift:${SWIFT_VERSION}-amazonlinux2-dev

clean_lambda:
	rm $(EXAMPLE_PROJECT_PATH)/$(LAMBDA_ZIP) || true
	rm -rf $(EXAMPLE_PROJECT_PATH)/.build || true

build_lambda:
	docker run \
			--rm \
			--volume "$(shell pwd)/:/src" \
			--workdir "/src/$(EXAMPLE_PROJECT_PATH)" \
			$(SWIFT_DOCKER_IMAGE) \
			swift build -c release

package_lambda: build_lambda
	cp $(EXAMPLE_PROJECT_PATH)/.build/release/$(EXAMPLE_EXECUTABLE) $(EXAMPLE_PROJECT_PATH)/bootstrap
	zip -r -j $(LAMBDA_ZIP) $(EXAMPLE_PROJECT_PATH)/bootstrap
	
test_lambda: package_lambda
	echo '{"number": 9 }' | sam local invoke --template $(EXAMPLE_PROJECT_PATH)/template.yaml -v . "SquareNumberFunction"
	echo '{"number": 3 }' | sam local invoke --template $(EXAMPLE_PROJECT_PATH)/template.yaml -v . "PrintNumberFunction"

