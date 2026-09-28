#import <XCTest/XCTest.h>

#include "BrokerEnvelope.h"

#include <string.h>

@interface JortBrokerEnvelopeTests : XCTestCase
@end

@implementation JortBrokerEnvelopeTests

- (xpc_object_t)validRequestWithOperation:(uint64_t)operation
                                     input:(const void *)input
                               inputLength:(size_t)inputLength {
    static const uint8_t nonce[16] = {0};
    static const uint8_t invocation[16] = {1};
    static const uint8_t generation[16] = {2};
    static const char contract[] = "{}";
    static const char source[] = "export default {}";
    static const char clock[] = "{}";
    static const char uuid[] = "00000000-0000-4000-8000-000000000000";

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(request, "version", JORT_JS_VERSION);
    xpc_dictionary_set_uint64(request, "operation", operation);
    xpc_dictionary_set_data(request, "nonce", nonce, sizeof(nonce));
    xpc_dictionary_set_data(request, "invocation", invocation, sizeof(invocation));
    xpc_dictionary_set_data(request, "generation", generation, sizeof(generation));
    xpc_dictionary_set_data(request, "contract", contract, sizeof(contract) - 1);
    xpc_dictionary_set_data(request, "source", source, sizeof(source) - 1);
    xpc_dictionary_set_data(request, "input", input, inputLength);
    xpc_dictionary_set_data(request, "clock", clock, sizeof(clock) - 1);
    xpc_dictionary_set_data(request, "uuid", uuid, sizeof(uuid) - 1);
    xpc_dictionary_set_uint64(request, "deadlineMilliseconds", 1000);
    xpc_dictionary_set_uint64(request, "outputBytes", JORT_JS_OUTPUT_MAX);
    xpc_dictionary_set_uint64(request, "outputLines", JORT_JS_LINES_MAX);
    XCTAssertEqual(xpc_dictionary_get_count(request), 13u);
    return request;
}

- (void)testValidateInputRequestWithContentDecodes {
    static const char input[] = "{\"name\":\"Ada\"}";
    xpc_object_t request = [self validRequestWithOperation:JORT_JS_VALIDATE_INPUT
                                                      input:input
                                                inputLength:sizeof(input) - 1];
    JortJSFrame frame = {0};

    XCTAssertTrue(jort_broker_decode_request(request, &frame));
    XCTAssertEqual(frame.tag, (uint32_t)JORT_JS_VALIDATE_INPUT);
    XCTAssertEqual(frame.lengths[2], sizeof(input) - 1);
    XCTAssertEqual(memcmp(frame.fields[2], input, sizeof(input) - 1), 0);

    jort_js_frame_destroy(&frame);
}

- (void)testRejectsRequestsWithoutTheExactVersionedThirteenKeyShape {
    static const char input[] = "{}";

    xpc_object_t missing = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_value(missing, "uuid", NULL);
    JortJSFrame frame = {0};
    XCTAssertFalse(jort_broker_decode_request(missing, &frame));

    xpc_object_t unknown = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_string(unknown, "unexpected", "field");
    XCTAssertFalse(jort_broker_decode_request(unknown, &frame));

    xpc_object_t wrongType = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_string(wrongType, "operation", "execute");
    XCTAssertFalse(jort_broker_decode_request(wrongType, &frame));

    xpc_object_t wrongVersion = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_uint64(wrongVersion, "version", JORT_JS_VERSION + 1);
    XCTAssertFalse(jort_broker_decode_request(wrongVersion, &frame));
}

- (void)testDecodedRequestRejectsInvalidUTF8AtFrameValidation {
    static const uint8_t invalidUTF8[] = { 0xc0, 0x80 };
    xpc_object_t request = [self validRequestWithOperation:JORT_JS_EXECUTE
                                                     input:invalidUTF8
                                               inputLength:sizeof(invalidUTF8)];
    JortJSFrame frame = {0};
    XCTAssertTrue(jort_broker_decode_request(request, &frame));
    XCTAssertEqual(jort_js_frame_validate(&frame), JORT_JS_IO_INVALID);
    jort_js_frame_destroy(&frame);
}

- (void)testAcceptsMaximumLegalRequestEnvelope {
    NSMutableData *contract = [NSMutableData dataWithLength:JORT_JS_CONTRACT_MAX];
    NSMutableData *source = [NSMutableData dataWithLength:JORT_JS_SOURCE_MAX];
    NSMutableData *input = [NSMutableData dataWithLength:JORT_JS_INPUT_MAX];
    NSMutableData *clock = [NSMutableData dataWithLength:JORT_JS_METADATA_MAX - 36];
    memset(contract.mutableBytes, 'c', contract.length);
    memset(source.mutableBytes, 's', source.length);
    memset(input.mutableBytes, 'i', input.length);
    memset(clock.mutableBytes, 't', clock.length);
    static const char uuid[] = "00000000-0000-4000-8000-000000000000";
    xpc_object_t request = [self validRequestWithOperation:JORT_JS_EXECUTE input:input.bytes inputLength:input.length];
    xpc_dictionary_set_data(request, "contract", contract.bytes, contract.length);
    xpc_dictionary_set_data(request, "source", source.bytes, source.length);
    xpc_dictionary_set_data(request, "input", input.bytes, input.length);
    xpc_dictionary_set_data(request, "clock", clock.bytes, clock.length);
    xpc_dictionary_set_data(request, "uuid", uuid, sizeof(uuid) - 1);

    JortJSFrame frame = {0};
    XCTAssertTrue(jort_broker_decode_request(request, &frame));
    XCTAssertEqual(frame.lengths[0], JORT_JS_CONTRACT_MAX);
    XCTAssertEqual(frame.lengths[1], JORT_JS_SOURCE_MAX);
    XCTAssertEqual(frame.lengths[2], JORT_JS_INPUT_MAX);
    XCTAssertEqual(frame.lengths[3] + frame.lengths[4], JORT_JS_METADATA_MAX);
    jort_js_frame_destroy(&frame);
}

- (void)testRejectsWrongTypedPayloadAndOversizedContract {
    static const char input[] = "{}";
    xpc_object_t wrongType = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_string(wrongType, "nonce", "not data");
    JortJSFrame frame = {0};
    XCTAssertFalse(jort_broker_decode_request(wrongType, &frame));

    NSMutableData *oversizedContract = [NSMutableData dataWithLength:JORT_JS_CONTRACT_MAX + 1];
    xpc_object_t oversized = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_data(oversized, "contract", oversizedContract.bytes, oversizedContract.length);
    XCTAssertFalse(jort_broker_decode_request(oversized, &frame));
}

- (void)testRejectsIndependentAndAggregatePayloadLimitsBeforeCopying {
    static const char input[] = "{}";

    NSMutableData *oversizedSource = [NSMutableData dataWithLength:JORT_JS_SOURCE_MAX + 1];
    xpc_object_t sourceLimit = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_data(sourceLimit, "source", oversizedSource.bytes, oversizedSource.length);
    JortJSFrame frame = {0};
    XCTAssertFalse(jort_broker_decode_request(sourceLimit, &frame));

    NSMutableData *oversizedInput = [NSMutableData dataWithLength:JORT_JS_INPUT_MAX + 1];
    xpc_object_t inputLimit = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_data(inputLimit, "input", oversizedInput.bytes, oversizedInput.length);
    XCTAssertFalse(jort_broker_decode_request(inputLimit, &frame));

    // Each metadata member is individually in range, but their aggregate is not.
    NSMutableData *maximumClock = [NSMutableData dataWithLength:JORT_JS_METADATA_MAX];
    xpc_object_t metadataLimit = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_data(metadataLimit, "clock", maximumClock.bytes, maximumClock.length);
    XCTAssertFalse(jort_broker_decode_request(metadataLimit, &frame));
}

- (void)testRejectsOutOfRangeNumericAndFixedIdentityValues {
    static const char input[] = "{}";
    JortJSFrame frame = {0};

    xpc_object_t operation = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_uint64(operation, "operation", UINT64_MAX);
    XCTAssertFalse(jort_broker_decode_request(operation, &frame));

    xpc_object_t deadline = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_uint64(deadline, "deadlineMilliseconds", 30001);
    XCTAssertFalse(jort_broker_decode_request(deadline, &frame));

    xpc_object_t output = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_uint64(output, "outputBytes", JORT_JS_OUTPUT_MAX + 1);
    XCTAssertFalse(jort_broker_decode_request(output, &frame));

    xpc_object_t lines = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_uint64(lines, "outputLines", JORT_JS_LINES_MAX + 1);
    XCTAssertFalse(jort_broker_decode_request(lines, &frame));

    static const uint8_t shortNonce[15] = {0};
    xpc_object_t nonce = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_data(nonce, "nonce", shortNonce, sizeof(shortNonce));
    XCTAssertFalse(jort_broker_decode_request(nonce, &frame));

    static const char shortUUID[] = "00000000-0000-4000-8000-00000000000";
    xpc_object_t uuid = [self validRequestWithOperation:JORT_JS_EXECUTE input:input inputLength:2];
    xpc_dictionary_set_data(uuid, "uuid", shortUUID, sizeof(shortUUID) - 1);
    XCTAssertFalse(jort_broker_decode_request(uuid, &frame));
}

- (void)testDecodedRequestRejectsNulAtFrameValidation {
    static const uint8_t nulInput[] = { 'a', 0, 'b' };
    xpc_object_t request = [self validRequestWithOperation:JORT_JS_EXECUTE
                                                     input:nulInput
                                               inputLength:sizeof(nulInput)];
    JortJSFrame frame = {0};
    XCTAssertTrue(jort_broker_decode_request(request, &frame));
    XCTAssertEqual(jort_js_frame_validate(&frame), JORT_JS_IO_INVALID);
    jort_js_frame_destroy(&frame);
}

@end
