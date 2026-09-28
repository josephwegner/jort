#ifndef JORT_BROKER_ENVELOPE_H
#define JORT_BROKER_ENVELOPE_H

#include "JortJavaScriptProtocol.h"
#include <xpc/xpc.h>

/* Performs the entire shape/size pass before allocating any payload copies. */
bool jort_broker_decode_request(xpc_object_t message, JortJSFrame *frame);
xpc_object_t jort_broker_create_reply(xpc_object_t request, const JortJSFrame *response);

#endif
