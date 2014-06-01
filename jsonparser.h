#ifndef _JSONPARSER_H                        /* duplication check */
#define _JSONPARSER_H

#if defined(__cplusplus)
#define __JSONPARSER_CLINKAGEBEGIN extern "C" {
#define __JSONPARSER_CLINKAGEEND }
#else
#define __JSONPARSER_CLINKAGEBEGIN
#define __JSONPARSER_CLINKAGEEND
#endif
__JSONPARSER_CLINKAGEBEGIN

#include <stdlib.h>
#if ! defined(__cplusplus)
#include <stdbool.h>
#endif
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#ifndef JSONPARSERAPI
#define JSONPARSERAPI /* nothing */
#endif

/* JSON references:

   http://www.json.org/
   http://www.json.org/example.html

 */

typedef void *JSONParser;

#define jsonParserGetUserData(parser) (*(void **)(parser))

enum JSON_PARSER_ERROR {
	JSON_PARSER_ERROR_UNKNOWN = -1,
	JSON_PARSER_ERROR_NONE,
	/* Alphabetical order from here. */
	JSON_PARSER_ERROR_BUFFER,
	JSON_PARSER_ERROR_MEMORY,
	JSON_PARSER_ERROR_PARSER,
	JSON_PARSER_ERROR_PSTACK,
	JSON_PARSER_ERROR_READER,
	JSON_PARSER_ERROR_WRITER
};

enum JSON_PARSER_VALUE_TYPE {
	JSON_PARSER_VALUE_TYPE_NONE,
	JSON_PARSER_VALUE_TYPE_STRING,
	JSON_PARSER_VALUE_TYPE_NUMBER,
	JSON_PARSER_VALUE_TYPE_OBJECT,
	JSON_PARSER_VALUE_TYPE_ARRAY,
	JSON_PARSER_VALUE_TYPE_TRUE,
	JSON_PARSER_VALUE_TYPE_FALSE,
	JSON_PARSER_VALUE_TYPE_NULL
};

#define JSON_PARSER_BUFFER_SIZE 32768

typedef struct JSONParserBufferStruct {
	const char *data;
	size_t size;
} JSONParserBuffer, *JSONParserBufferPtr;

JSONParserBuffer defaultJSONParserBuffer = {
	NULL, JSON_PARSER_BUFFER_SIZE
};

JSONParserBuffer emptyJSONParserBuffer = {
	NULL, 0
};

typedef struct JSONParserValueStruct {
	enum JSON_PARSER_VALUE_TYPE type;
	void *item;
	double number;
	char *string;
} JSONParserValue, *JSONParserValuePtr;

JSONParserValue emptyJSONParserValue = {
	JSON_PARSER_VALUE_TYPE_NONE, NULL, 0.0, NULL
};

/* Builders */
typedef bool (*BuildAddElementFunc)(void *userData, void *item, JSONParserValue *value);
typedef bool (*BuildNewItemFunc)(void *userData, JSONParserValue *value/*, int depth*/);
typedef bool (*BuildSetMemberFunc)(void *userData, void *item, char *name, JSONParserValue *value);

/* Readers */
typedef bool (*ReaderFunc)(void *userData, JSONParserBuffer *buffer, size_t *size);

/* Writers */
typedef bool (*WriteArrayElementFunc)(void *userData, JSONParserValue *value);
typedef bool (*WriteObjectMemberFunc)(void *userData, char *name, JSONParserValue *value);
typedef bool (*WriteStartFunc)(void *userData);
typedef bool (*WriteStartArrayFunc)(void *userData, char *name);
typedef bool (*WriteStartObjectFunc)(void *userData, char *name);
typedef bool (*WriteStopFunc)(void *userData);
typedef bool (*WriteStopArrayFunc)(void *userData);
typedef bool (*WriteStopObjectFunc)(void *userData);

typedef struct JSONParserConfigStruct {
	/* Builders */
	BuildAddElementFunc buildAddElement;
	BuildNewItemFunc buildNewItem;
	BuildSetMemberFunc buildSetMember;
	/* Writers */
	WriteArrayElementFunc writeArrayElement;
	WriteObjectMemberFunc writeObjectMember;
	WriteStartFunc writeStart;
	WriteStartArrayFunc writeStartArray;
	WriteStartObjectFunc writeStartObject;
	WriteStopFunc writeStop;
	WriteStopArrayFunc writeStopArray;
	WriteStopObjectFunc writeStopObject;
} JSONParserConfig, *JSONParserConfigPtr;

JSONParserConfig emptyJSONParserConfig = {
	NULL, NULL, NULL, 
	NULL, NULL, 
	NULL, NULL, NULL, 
	NULL, NULL, NULL
};

#if !defined(NDEBUG)
extern int g_jsonParserStringCounter;
#endif

/* function prototypes */

JSONParser JSONPARSERAPI createJSONParser(JSONParserConfig *config);
JSONParserBuffer JSONPARSERAPI *createJSONParserBuffer(size_t size);
char JSONPARSERAPI *createJSONParserString(const char *data, size_t size);
void JSONPARSERAPI jsonParserBufferFree(JSONParserBuffer *buffer);
void JSONPARSERAPI jsonParserConfigureBuilders(JSONParser parser, BuildAddElementFunc buildAddElement, 
		BuildNewItemFunc buildNewItem, BuildSetMemberFunc buildSetMember);
void JSONPARSERAPI jsonParserConfigureWriters(JSONParser parser, 
		WriteArrayElementFunc writeArrayElement, WriteObjectMemberFunc writeObjectMember, 
		WriteStartFunc writeStart, WriteStartArrayFunc writeStartArray, WriteStartObjectFunc writeStartObject, 
		WriteStopFunc writeStop, WriteStopArrayFunc writeStopArray, WriteStopObjectFunc writeStopObject);
void JSONPARSERAPI jsonParserFree(JSONParser parser);
int JSONPARSERAPI jsonParserGetCurrentLine(JSONParser parser);
enum JSON_PARSER_ERROR JSONPARSERAPI jsonParserGetErrorCode(JSONParser parser);
const char JSONPARSERAPI *jsonParserGetErrorString(JSONParser parser);
bool JSONPARSERAPI jsonParserParseStream(JSONParser parser, JSONParserBuffer *buffer, ReaderFunc reader, void *item, char *name);
bool JSONPARSERAPI jsonParserParseString(JSONParser parser, char *string, void *item, char *name);
void JSONPARSERAPI *jsonParserSetUserData(JSONParser parser, void *userData);
bool jsonParserStandardInputReader(void *userData, JSONParserBuffer *buffer, size_t *size);
char JSONPARSERAPI *jsonParserStringAppend(char *string, const char *data, size_t size);
void JSONPARSERAPI jsonParserStringFree(char *string);

/* library management */

// Release:	28 October 2010 - 0.0.2
//			* Added support for builders and writers.

// Release:	27 October 2010 - 0.0.1
//			* Initial release for discussion.

#define _JSON_VERSION    "0.0.2"
#define _JSON_LIBVER     101
#define _JSON_FORMATVER  "1.0"

__JSONPARSER_CLINKAGEEND
#endif                                   /* duplication check */

/* END OF FILE */
