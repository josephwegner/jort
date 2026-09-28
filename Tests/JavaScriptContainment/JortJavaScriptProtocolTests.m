#import <XCTest/XCTest.h>

#include "JortJavaScriptProtocol.h"

#include <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

@interface JortJavaScriptProtocolTests : XCTestCase
@end

@implementation JortJavaScriptProtocolTests

- (JortJSFrame)validRequestWithContract:(const uint8_t *)contract
                          contractLength:(uint32_t)contractLength
                                  source:(const uint8_t *)source
                            sourceLength:(uint32_t)sourceLength
                                   input:(const uint8_t *)input
                             inputLength:(uint32_t)inputLength {
    JortJSFrame frame = {0};
    frame.kind = JORT_JS_REQUEST;
    frame.tag = JORT_JS_EXECUTE;
    frame.deadline_ms = 1000;
    frame.output_bytes = JORT_JS_OUTPUT_MAX;
    frame.output_lines = JORT_JS_LINES_MAX;
    for (unsigned index = 0; index < 16; ++index) {
        frame.nonce[index] = (uint8_t)index;
        frame.invocation[index] = (uint8_t)(16 + index);
        frame.generation[index] = (uint8_t)(32 + index);
    }
    frame.lengths[0] = contractLength;
    frame.lengths[1] = sourceLength;
    frame.lengths[2] = inputLength;
    frame.fields[0] = (uint8_t *)contract;
    frame.fields[1] = (uint8_t *)source;
    frame.fields[2] = (uint8_t *)input;
    return frame;
}

- (void)testMaximumValidRequestHeaderRoundTrips {
    uint8_t *contract = malloc(JORT_JS_CONTRACT_MAX);
    uint8_t *source = malloc(JORT_JS_SOURCE_MAX);
    uint8_t *input = malloc(JORT_JS_INPUT_MAX);
    uint8_t *clock = malloc(JORT_JS_METADATA_MAX - 1);
    XCTAssertTrue(contract != NULL);
    XCTAssertTrue(source != NULL);
    XCTAssertTrue(input != NULL);
    XCTAssertTrue(clock != NULL);
    memset(contract, 'c', JORT_JS_CONTRACT_MAX);
    memset(source, 's', JORT_JS_SOURCE_MAX);
    memset(input, 'i', JORT_JS_INPUT_MAX);
    memset(clock, 't', JORT_JS_METADATA_MAX - 1);

    JortJSFrame frame = [self validRequestWithContract:contract
                                         contractLength:JORT_JS_CONTRACT_MAX
                                                 source:source
                                           sourceLength:JORT_JS_SOURCE_MAX
                                                  input:input
                                            inputLength:JORT_JS_INPUT_MAX];
    frame.lengths[3] = JORT_JS_METADATA_MAX - 1;
    frame.lengths[4] = 1;
    frame.fields[3] = clock;
    frame.fields[4] = (uint8_t *)"u";
    uint8_t header[JORT_JS_HEADER_SIZE];
    XCTAssertEqual(jort_js_frame_validate(&frame), JORT_JS_IO_OK);
    XCTAssertEqual(jort_js_header_encode(&frame, header), JORT_JS_IO_OK);

    JortJSFrame decoded = {0};
    XCTAssertEqual(jort_js_header_decode(header, &decoded), JORT_JS_IO_OK);
    XCTAssertEqual(memcmp(decoded.generation, frame.generation, sizeof(frame.generation)), 0);
    XCTAssertEqual(decoded.lengths[0], JORT_JS_CONTRACT_MAX);
    XCTAssertEqual(decoded.lengths[1], JORT_JS_SOURCE_MAX);
    XCTAssertEqual(decoded.lengths[2], JORT_JS_INPUT_MAX);
    XCTAssertEqual(decoded.lengths[3] + decoded.lengths[4], JORT_JS_METADATA_MAX);

    char path[] = "/tmp/jort-js-request-XXXXXX";
    int fd = mkstemp(path);
    XCTAssertGreaterThanOrEqual(fd, 0);
    unlink(path);
    XCTAssertEqual(jort_js_frame_write(fd, &frame, jort_js_monotonic() + 5), JORT_JS_IO_OK);
    XCTAssertEqual(lseek(fd, 0, SEEK_SET), 0);
    JortJSFrame decodedRequest = {0};
    XCTAssertEqual(jort_js_frame_read(fd, &decodedRequest, jort_js_monotonic() + 5), JORT_JS_IO_OK);
    XCTAssertEqual(decodedRequest.lengths[0], JORT_JS_CONTRACT_MAX);
    XCTAssertEqual(decodedRequest.lengths[1], JORT_JS_SOURCE_MAX);
    XCTAssertEqual(decodedRequest.lengths[2], JORT_JS_INPUT_MAX);
    XCTAssertEqual(decodedRequest.lengths[3] + decodedRequest.lengths[4], JORT_JS_METADATA_MAX);
    jort_js_frame_destroy(&decodedRequest);
    close(fd);

    free(contract);
    free(source);
    free(input);
    free(clock);
}

- (void)testRequestRejectsSummedMetadataAndOverflowedLengths {
    static const uint8_t contract[] = "{}";
    static const uint8_t source[] = "source";
    JortJSFrame frame = [self validRequestWithContract:contract
                                         contractLength:sizeof(contract) - 1
                                                 source:source
                                           sourceLength:sizeof(source) - 1
                                                  input:NULL
                                            inputLength:0];
    uint8_t metadata[JORT_JS_METADATA_MAX + 1];
    memset(metadata, 'm', sizeof(metadata));
    frame.lengths[3] = JORT_JS_METADATA_MAX;
    frame.lengths[4] = 1;
    frame.fields[3] = metadata;
    frame.fields[4] = metadata + JORT_JS_METADATA_MAX;
    XCTAssertEqual(jort_js_frame_validate(&frame), JORT_JS_IO_INVALID);

    frame.lengths[3] = 0;
    frame.lengths[4] = 0;
    frame.lengths[0] = UINT32_MAX;
    XCTAssertEqual(jort_js_frame_validate(&frame), JORT_JS_IO_INVALID);
}

- (void)testMaximumLegalResponsesRoundTripOutputAndError {
    uint8_t *output = malloc(JORT_JS_OUTPUT_MAX);
    uint8_t *error = malloc(JORT_JS_ERROR_MAX);
    XCTAssertNotEqual(output, NULL);
    XCTAssertNotEqual(error, NULL);
    memset(output, 'o', JORT_JS_OUTPUT_MAX);
    memset(error, 'e', JORT_JS_ERROR_MAX);

    char path[] = "/tmp/jort-js-response-XXXXXX";
    int fd = mkstemp(path);
    XCTAssertGreaterThanOrEqual(fd, 0);
    unlink(path);

    JortJSFrame response = {0};
    response.kind = JORT_JS_RESPONSE;
    response.tag = JORT_JS_OK;
    response.lengths[0] = JORT_JS_OUTPUT_MAX;
    response.fields[0] = output;
    XCTAssertEqual(jort_js_frame_validate(&response), JORT_JS_IO_OK);
    XCTAssertEqual(jort_js_frame_write(fd, &response, jort_js_monotonic() + 5), JORT_JS_IO_OK);
    XCTAssertEqual(lseek(fd, 0, SEEK_SET), 0);
    JortJSFrame decoded = {0};
    XCTAssertEqual(jort_js_frame_read(fd, &decoded, jort_js_monotonic() + 5), JORT_JS_IO_OK);
    XCTAssertEqual(decoded.lengths[0], JORT_JS_OUTPUT_MAX);
    XCTAssertEqual(memcmp(decoded.fields[0], output, JORT_JS_OUTPUT_MAX), 0);
    jort_js_frame_destroy(&decoded);

    XCTAssertEqual(ftruncate(fd, 0), 0);
    XCTAssertEqual(lseek(fd, 0, SEEK_SET), 0);
    response.tag = JORT_JS_PROTOCOL;
    response.lengths[0] = 0;
    response.fields[0] = NULL;
    response.lengths[1] = JORT_JS_ERROR_MAX;
    response.fields[1] = error;
    XCTAssertEqual(jort_js_frame_validate(&response), JORT_JS_IO_OK);
    XCTAssertEqual(jort_js_frame_write(fd, &response, jort_js_monotonic() + 5), JORT_JS_IO_OK);
    XCTAssertEqual(lseek(fd, 0, SEEK_SET), 0);
    XCTAssertEqual(jort_js_frame_read(fd, &decoded, jort_js_monotonic() + 5), JORT_JS_IO_OK);
    XCTAssertEqual(decoded.lengths[1], JORT_JS_ERROR_MAX);
    XCTAssertEqual(memcmp(decoded.fields[1], error, JORT_JS_ERROR_MAX), 0);
    jort_js_frame_destroy(&decoded);
    close(fd);
    free(output);
    free(error);
}

- (void)testHeaderRejectsWrongVersionStructuralBytesAndInvalidLengths {
    static const uint8_t contract[] = "{}";
    static const uint8_t source[] = "export default {}";
    JortJSFrame frame = [self validRequestWithContract:contract
                                         contractLength:sizeof(contract) - 1
                                                 source:source
                                           sourceLength:sizeof(source) - 1
                                                  input:NULL
                                            inputLength:0];
    uint8_t header[JORT_JS_HEADER_SIZE];
    XCTAssertEqual(jort_js_header_encode(&frame, header), JORT_JS_IO_OK);

    JortJSFrame decoded = {0};
    header[5] = JORT_JS_VERSION + 1;
    XCTAssertEqual(jort_js_header_decode(header, &decoded), JORT_JS_IO_INVALID);

    XCTAssertEqual(jort_js_header_encode(&frame, header), JORT_JS_IO_OK);
    header[6] = 1;
    XCTAssertEqual(jort_js_header_decode(header, &decoded), JORT_JS_IO_INVALID);

    XCTAssertEqual(jort_js_header_encode(&frame, header), JORT_JS_IO_OK);
    // Field zero is encoded at offset 64 and may never exceed the contract cap.
    header[64] = 0xff;
    XCTAssertEqual(jort_js_header_decode(header, &decoded), JORT_JS_IO_INVALID);

    XCTAssertEqual(jort_js_header_encode(&frame, header), JORT_JS_IO_OK);
    // A validate request cannot carry invocation input.
    header[8 + 3] = JORT_JS_VALIDATE;
    header[64 + 2 * 4 + 3] = 1;
    XCTAssertEqual(jort_js_header_decode(header, &decoded), JORT_JS_IO_INVALID);
}

- (void)testFramesRejectNulAndMalformedUTF8 {
    static const uint8_t contract[] = "{}";
    static const uint8_t nulSource[] = { 'a', 0, 'b' };
    JortJSFrame frame = [self validRequestWithContract:contract
                                         contractLength:sizeof(contract) - 1
                                                 source:nulSource
                                           sourceLength:sizeof(nulSource)
                                                  input:NULL
                                            inputLength:0];
    XCTAssertEqual(jort_js_frame_validate(&frame), JORT_JS_IO_INVALID);

    static const uint8_t malformedSource[] = { 0xc0, 0x80 };
    frame.fields[1] = (uint8_t *)malformedSource;
    frame.lengths[1] = sizeof(malformedSource);
    XCTAssertEqual(jort_js_frame_validate(&frame), JORT_JS_IO_INVALID);
}

- (void)testReadRejectsInvalidUTF8EvenWithMatchingPayloadHash {
    static const uint8_t contract[] = "{}";
    static const uint8_t validSource[] = "xy";
    static const uint8_t invalidSource[] = { 0xc0, 0x80 };
    JortJSFrame frame = [self validRequestWithContract:contract
                                         contractLength:sizeof(contract) - 1
                                                 source:validSource
                                           sourceLength:sizeof(validSource) - 1
                                                  input:NULL
                                            inputLength:0];
    uint8_t header[JORT_JS_HEADER_SIZE];
    XCTAssertEqual(jort_js_header_encode(&frame, header), JORT_JS_IO_OK);

    CC_SHA256_CTX hashContext;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Init(&hashContext);
    CC_SHA256_Update(&hashContext, contract, sizeof(contract) - 1);
    CC_SHA256_Update(&hashContext, invalidSource, sizeof(invalidSource));
    CC_SHA256_Final(digest, &hashContext);
    memcpy(header + 96, digest, sizeof(digest));

    int pipes[2];
    XCTAssertEqual(pipe(pipes), 0);
    XCTAssertEqual(write(pipes[1], header, sizeof(header)), sizeof(header));
    XCTAssertEqual(write(pipes[1], contract, sizeof(contract) - 1), sizeof(contract) - 1);
    XCTAssertEqual(write(pipes[1], invalidSource, sizeof(invalidSource)), sizeof(invalidSource));
    close(pipes[1]);
    JortJSFrame decoded = {0};
    XCTAssertEqual(jort_js_frame_read(pipes[0], &decoded, jort_js_monotonic() + 1), JORT_JS_IO_INVALID);
    close(pipes[0]);
}

- (void)testReadRejectsNulPayloadEvenWithMatchingPayloadHash {
    static const uint8_t contract[] = "{}";
    static const uint8_t validSource[] = "xy";
    static const uint8_t nulSource[] = { 'x', 0, 'y' };
    JortJSFrame frame = [self validRequestWithContract:contract
                                         contractLength:sizeof(contract) - 1
                                                 source:validSource
                                           sourceLength:sizeof(validSource) - 1
                                                  input:NULL
                                            inputLength:0];
    uint8_t header[JORT_JS_HEADER_SIZE];
    // Construct a syntactically valid header whose hash covers the NUL payload.
    XCTAssertEqual(jort_js_header_encode(&frame, header), JORT_JS_IO_OK);
    header[64 + 4 + 3] = sizeof(nulSource);
    CC_SHA256_CTX hashContext;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Init(&hashContext);
    CC_SHA256_Update(&hashContext, contract, sizeof(contract) - 1);
    CC_SHA256_Update(&hashContext, nulSource, sizeof(nulSource));
    CC_SHA256_Final(digest, &hashContext);
    memcpy(header + 96, digest, sizeof(digest));

    int pipes[2];
    XCTAssertEqual(pipe(pipes), 0);
    XCTAssertEqual(write(pipes[1], header, sizeof(header)), sizeof(header));
    XCTAssertEqual(write(pipes[1], contract, sizeof(contract) - 1), sizeof(contract) - 1);
    XCTAssertEqual(write(pipes[1], nulSource, sizeof(nulSource)), sizeof(nulSource));
    close(pipes[1]);
    JortJSFrame decoded = {0};
    XCTAssertEqual(jort_js_frame_read(pipes[0], &decoded, jort_js_monotonic() + 1), JORT_JS_IO_INVALID);
    close(pipes[0]);
}

- (void)testHeaderRejectsOverflowedResponseLength {
    static const uint8_t output[] = "ok";
    JortJSFrame response = {0};
    response.kind = JORT_JS_RESPONSE;
    response.tag = JORT_JS_OK;
    response.lengths[0] = sizeof(output) - 1;
    response.fields[0] = (uint8_t *)output;
    uint8_t header[JORT_JS_HEADER_SIZE];
    XCTAssertEqual(jort_js_header_encode(&response, header), JORT_JS_IO_OK);

    // Output length is a big-endian 32-bit integer at header offset 64.
    header[64] = 0x00;
    header[65] = 0x10;
    header[66] = 0x00;
    header[67] = 0x01;
    JortJSFrame decoded = {0};
    XCTAssertEqual(jort_js_header_decode(header, &decoded), JORT_JS_IO_INVALID);
}

- (void)testReadRejectsTruncationHashTamperingAndTrailingData {
    static const uint8_t contract[] = "{}";
    static const uint8_t source[] = "export default {}";
    JortJSFrame frame = [self validRequestWithContract:contract
                                         contractLength:sizeof(contract) - 1
                                                 source:source
                                           sourceLength:sizeof(source) - 1
                                                  input:NULL
                                            inputLength:0];
    uint8_t header[JORT_JS_HEADER_SIZE];
    XCTAssertEqual(jort_js_header_encode(&frame, header), JORT_JS_IO_OK);

    int pipes[2];
    XCTAssertEqual(pipe(pipes), 0);
    XCTAssertEqual(write(pipes[1], header, sizeof(header)), sizeof(header));
    close(pipes[1]);
    JortJSFrame decoded = {0};
    XCTAssertEqual(jort_js_frame_read(pipes[0], &decoded, jort_js_monotonic() + 1), JORT_JS_IO_CLOSED);
    close(pipes[0]);

    XCTAssertEqual(pipe(pipes), 0);
    XCTAssertEqual(write(pipes[1], header, sizeof(header)), sizeof(header));
    XCTAssertEqual(write(pipes[1], contract, sizeof(contract) - 1), sizeof(contract) - 1);
    uint8_t tampered[] = "export default []";
    XCTAssertEqual(write(pipes[1], tampered, sizeof(source) - 1), sizeof(source) - 1);
    close(pipes[1]);
    XCTAssertEqual(jort_js_frame_read(pipes[0], &decoded, jort_js_monotonic() + 1), JORT_JS_IO_INVALID);
    close(pipes[0]);

    XCTAssertEqual(pipe(pipes), 0);
    XCTAssertEqual(jort_js_frame_write(pipes[1], &frame, jort_js_monotonic() + 1), JORT_JS_IO_OK);
    // A second complete frame is forbidden just like any trailing byte.
    XCTAssertEqual(jort_js_frame_write(pipes[1], &frame, jort_js_monotonic() + 1), JORT_JS_IO_OK);
    close(pipes[1]);
    XCTAssertEqual(jort_js_frame_read(pipes[0], &decoded, jort_js_monotonic() + 1), JORT_JS_IO_OK);
    XCTAssertEqual(jort_js_expect_eof(pipes[0], jort_js_monotonic() + 1), JORT_JS_IO_INVALID);
    jort_js_frame_destroy(&decoded);
    close(pipes[0]);
}

- (void)testReadyRoundTripAndRejectsUnexpectedPolicy {
    JortJSReady ready = { JORT_JS_OK, 2, 3, JORT_JS_NOFILE };
    int pipes[2];
    XCTAssertEqual(pipe(pipes), 0);
    XCTAssertEqual(jort_js_ready_write(pipes[1], &ready, jort_js_monotonic() + 1), JORT_JS_IO_OK);
    close(pipes[1]);
    JortJSReady decoded = {0};
    XCTAssertEqual(jort_js_ready_read(pipes[0], &decoded, jort_js_monotonic() + 1), JORT_JS_IO_OK);
    XCTAssertEqual(decoded.cpu_hard, 3u);
    close(pipes[0]);

    XCTAssertEqual(pipe(pipes), 0);
    const uint8_t malformed[JORT_JS_READY_SIZE] = {
        'J', 'J', 'R', '1', 0, JORT_JS_VERSION, 0, JORT_JS_POLICY_VERSION + 1
    };
    XCTAssertEqual(write(pipes[1], malformed, sizeof(malformed)), sizeof(malformed));
    close(pipes[1]);
    XCTAssertEqual(jort_js_ready_read(pipes[0], &decoded, jort_js_monotonic() + 1), JORT_JS_IO_INVALID);
    close(pipes[0]);
}

@end
