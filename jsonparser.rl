//======================================================================
//
// Author:	Mark Wharton
//
// Date:	28th October 2010
//
// Title:	JSON Parser
//
// Version:	0.0.2
//
// Topic:	Introduction
//			**Features**
//			
//			Parse [[http://www.json.org/|JSON]] and optionally build the parse tree with callbacks:
//			
//			**Dependencies**
//			
//			* [[http://www.complang.org/ragel/|ragel]] for building jsonparser library
//			* [[http://fallabs.com/tokyocabinet/|tokyocabinet]] for json test application
//			
//			**Installation**
//			
//			Run the configuration script.
//			{{{
//			  ./configure
//			}}}
//			
//			Build the library and programs.
//			{{{
//			  make
//			}}}
//			
//			Install the library and programs.
//			{{{
//			  sudo make install
//			}}}
//			
//			**Using the JSON Library**
//			
//			{{{
//			  gcc -I/usr/local/include jsonapp.c -o jsonapp -L/usr/local/lib -ljsonparser
//			}}}
//			
//			**Sample JSON Application**
//			
//			{{{
//			#include <jsonparser.h>
//			
//			char *jsonTypes[] = { NULL, "string", "number", "{}", "[]", "true", "false", "null" };
//			
//			bool jsonAddElement(void *userData, void *item, JSONParserValue *value)
//			{
//			  char *elementValue = value->string; /* string and number */
//			  elementValue = elementValue ? elementValue : jsonTypes[value->type];
//			  return fprintf(stdout, "element: %s\n", elementValue) > 0;
//			}
//			
//			bool jsonSetMember(void *userData, void *item, char *name, JSONParserValue *value)
//			{
//			  char *memberValue = value->string; /* string and number */
//			  memberValue = memberValue ? memberValue : jsonTypes[value->type];
//			  return fprintf(stdout, "member: %s = %s\n", name, memberValue) > 0;
//			}
//			
//			int main(int argc, char **argv)
//			{
//			  JSONParser parser = createJSONParser(NULL);
//			  if (parser) {
//			    jsonParserConfigureBuilders(parser, jsonAddElement, NULL, jsonSetMember);
//			    JSONParserBuffer *buffer = createJSONParserBuffer(JSON_PARSER_BUFFER_SIZE);
//			    if (buffer) {
//			      if (!jsonParserParseStream(parser, buffer, NULL, NULL, NULL)) {
//			        fprintf(stderr, "Error: parser error: %d %s (line %d)\n", 
//			          jsonParserGetErrorCode(parser), jsonParserGetErrorString(parser), 
//			          jsonParserGetCurrentLine(parser));
//			        return 1;
//			      }
//			      jsonParserBufferFree(buffer);
//			      buffer = NULL;
//			    } else {
//			      fprintf(stderr, "Error: could not allocate buffer: %lld\n", (long long)buffer->size);
//			      return 1;
//			    }
//			    jsonParserFree(parser);
//			    parser = NULL;
//			  } else {
//			    fprintf(stderr, "Error: could not create parser\n");
//			    return 1;
//			  }
//			  return 0;
//			}
//			}}}
//			
//			**Values**
//			
//			The following value types are defined:
//			|= Value Types                            |= Field               |
//			| ##JSON_PARSER_VALUE_TYPE_NONE##         |                      |
//			| ##JSON_PARSER_VALUE_TYPE_STRING [1]##   | ##string##           |
//			| ##JSON_PARSER_VALUE_TYPE_NUMBER [1,2]## | ##number ~| string## |
//			| ##JSON_PARSER_VALUE_TYPE_OBJECT##       | ##item##             |
//			| ##JSON_PARSER_VALUE_TYPE_ARRAY##        | ##item##             |
//			| ##JSON_PARSER_VALUE_TYPE_TRUE##         |                      |
//			| ##JSON_PARSER_VALUE_TYPE_FALSE##        |                      |
//			| ##JSON_PARSER_VALUE_TYPE_NULL##         |                      |
//			**Special Notes:**
//			# The string must be copied, value string destroyed on callback return.
//			# The number type provides the value as ##double## and also ##string## for convenience.
//

// TODO LIST:
// [ ] think about pretty json printing with enter/exit
//     note: we only need the stack for builders
// [ ] number to support more features
// [ ] test '\\/' escape
// [ ] ...

#include "jsonparser.h"
#include "ragelstuff.h"

#if !defined(NDEBUG)
int g_jsonParserStringCounter = 0;
#endif

#define MARKER_free 0
#define MAX_MARKER 1
#define MAX_PSTACK 128

typedef struct JSONParserParserStruct {
	void *userData; /* First for jsonParserGetUserData macro. */
	JSONParserConfig config; /* Second for special access. */
	int currentLine;
	enum JSON_PARSER_ERROR error;
	struct FiniteStateMachineStruct {
		int act;
		int cs;
		const char *ts;
		const char *te;
		int stack[MAX_PSTACK];
		int top;
	} fsm;
	const char *marker[MAX_MARKER];
	struct StackStruct {
		void *item[MAX_PSTACK];
		char *name[MAX_PSTACK];
	} stack;
	int top;
	struct ValueStruct {
		char numberString[64];
		char *string;
		enum JSON_PARSER_VALUE_TYPE type;
	} value;
} JSONParserParser, *JSONParserParserPtr;

#define parserConfig (((JSONParserParserPtr)parser)->config)
#define parserCurrentLine (((JSONParserParserPtr)parser)->currentLine)
#define parserError (((JSONParserParserPtr)parser)->error)
#define parserFSM (((JSONParserParserPtr)parser)->fsm)
#define parserMark(mark) (((JSONParserParserPtr)parser)->marker[MARKER_ ## mark])
#define parserMarker (((JSONParserParserPtr)parser)->marker)
#define parserStack (((JSONParserParserPtr)parser)->stack)
#define parserTop (((JSONParserParserPtr)parser)->top)
#define parserUserData (((JSONParserParserPtr)parser)->userData)
#define parserValue (((JSONParserParserPtr)parser)->value)

// private function prototypes

bool jsonParserBuildAddElement(JSONParser parser);
bool jsonParserBuildNewItem(JSONParser parser);
bool jsonParserBuildSetMember(JSONParser parser);
int jsonParserUCS2ToUTF8(const uint16_t *ary, int num, char *str);
bool jsonParserValueString(JSONParser parser, const char *data, size_t size);
bool jsonParserWriteArrayElement(JSONParser parser);
bool jsonParserWriteObjectMember(JSONParser parser);
bool jsonParserWriteStart(JSONParser parser);
bool jsonParserWriteStartArray(JSONParser parser);
bool jsonParserWriteStartObject(JSONParser parser);
bool jsonParserWriteStop(JSONParser parser);
bool jsonParserWriteStopArray(JSONParser parser);
bool jsonParserWriteStopObject(JSONParser parser);

// FSM specification

%%{
	machine JSONParser;
	access parserFSM.;

	action string_scan {
		parserValue.type = JSON_PARSER_VALUE_TYPE_STRING;
		parserValue.string = NULL;
		fcall string_scanner;
	}

	action number {
		parserValue.type = JSON_PARSER_VALUE_TYPE_NUMBER;
		parserValue.numberString[0] = '\0';
	}

	action number_string {
		// JS Number.MAX_VALUE = 1.7976931348623157e+308
		int len = strlen(parserValue.numberString);
		parserValue.numberString[len++] = fc;
		parserValue.numberString[len] = '\0';
	}

	action object_enter { // push new item onto the stack and use
		parserValue.type = JSON_PARSER_VALUE_TYPE_OBJECT;
		if (!jsonParserWriteStartObject(parser)) fbreak;
		if (!jsonParserBuildNewItem(parser)) fbreak;
		fcall members;
	}

	action object_exit { // pop the stack
		if (!jsonParserWriteStopObject(parser)) fbreak;
		parserValue.type = JSON_PARSER_VALUE_TYPE_OBJECT;
		parserTop -= 1;
		fret;
	}

	action array_enter { // push new item onto the stack and use
		parserValue.type = JSON_PARSER_VALUE_TYPE_ARRAY;
		if (!jsonParserWriteStartArray(parser)) fbreak;
		if (!jsonParserBuildNewItem(parser)) fbreak;
		fcall elements;
	}

	action array_exit { // pop the stack
		if (!jsonParserWriteStopArray(parser)) fbreak;
		parserValue.type = JSON_PARSER_VALUE_TYPE_ARRAY;
		parserTop -= 1;
		fret;
	}

	action true {
		parserValue.type = JSON_PARSER_VALUE_TYPE_TRUE;
	}

	action false {
		parserValue.type = JSON_PARSER_VALUE_TYPE_FALSE;
	}

	action null {
		parserValue.type = JSON_PARSER_VALUE_TYPE_NULL;
	}

	action add_element {
		if (!jsonParserWriteArrayElement(parser)) fbreak;
		if (!jsonParserBuildAddElement(parser)) fbreak;
 		parserValue.type = JSON_PARSER_VALUE_TYPE_NONE;
	}

	action set_member {
		if (!jsonParserWriteObjectMember(parser)) fbreak;
		if (!jsonParserBuildSetMember(parser)) fbreak;
 		parserValue.type = JSON_PARSER_VALUE_TYPE_NONE;
	}

	action set_member_name {
		parserStack.name[parserTop - 1] = parserValue.string;
		parserValue.string = NULL;
	}

	action set_value {
 		if (parserTop == 1) {
			if (!jsonParserBuildSetMember(parser)) fbreak;
			parserValue.type = JSON_PARSER_VALUE_TYPE_NONE;
 		}
	}

	newline = '\n' @{ parserCurrentLine += 1; };
	space_count_line = ( [\r\t ] | newline );

	string_scanner := |*
	   '"'			   => {	fret; }; # terminate string
	   '\\"'		   => {	if (!jsonParserValueString(parser, "\"", 1)) fbreak; };
	   '\\/'		   => {	if (!jsonParserValueString(parser,  "/", 1)) fbreak; }; # To not confuse HTML!
	   '\\b'		   => {	if (!jsonParserValueString(parser, "\b", 1)) fbreak; };
	   '\\f'		   => {	if (!jsonParserValueString(parser, "\f", 1)) fbreak; };
	   '\\n'		   => {	if (!jsonParserValueString(parser, "\n", 1)) fbreak; };
	   '\\r'		   => {	if (!jsonParserValueString(parser, "\r", 1)) fbreak; };
	   '\\t'		   => {	if (!jsonParserValueString(parser, "\t", 1)) fbreak; };
	   '\\\\'		   => {	if (!jsonParserValueString(parser, "\\", 1)) fbreak; };
	   '\\u' xdigit{4} => {	char *ucs2 = (char *)parserFSM.ts + 2;
							int c, code = 0;
							for (int i = 0; i < 4; i++) {
								c = ucs2[i];
								if (c >= '0' && c <= '9') {
									code = code * 0x10 + c - '0';
								} else if (c >= 'A' && c <= 'F') {
									code = code * 0x10 + c - 'A' + 10;
								} else if (c >= 'a' && c <= 'f') {
									code = code * 0x10 + c - 'a' + 10;
								} else {
									break;
								}
							}
							char utf8string[16];
							uint16_t array[1];
							array[0] = code;
							int len = jsonParserUCS2ToUTF8(array, 1, utf8string);
							if (!jsonParserValueString(parser, utf8string, len)) fbreak; };
	   [^""\\]+		   => {	if (!jsonParserValueString(parser, parserFSM.ts, parserFSM.te - parserFSM.ts)) fbreak; };
	*|;

	string = '"' @string_scan;

	number = ( ( '-' | digit ) @number ( digit* ( '.' [0-9]+ )? ) ) $number_string; # Limited support!

	primitive = ( string | number | ( 'true' ) %true | ( 'false' ) %false | ( 'null' ) %null );

	value = ( primitive | '{' @object_enter | '[' @array_enter ) %set_value;

	element = ( space_count_line* value ) %add_element;

	elements := ( element ( space_count_line* ',' element )* )? space_count_line* ']' @array_exit;

	member = ( space_count_line* string %set_member_name space_count_line* ':' space_count_line* value ) %set_member;

	members := ( member ( space_count_line* ',' member )* )? space_count_line* '}' @object_exit;

	main := ( space_count_line* value* space_count_line* );
}%%

%% write data;

void jsonParserParserInit(JSONParser parser, void *item, char *name)
{
	parserCurrentLine = 1;
	parserStack.item[0] = item;
	parserStack.name[0] = name ? name : "root";
	parserTop = 1;
	/* Clear the stack for writers. */
	for (int i = parserTop; i < MAX_PSTACK; i++) {
		parserStack.item[i] = NULL;
		parserStack.name[i] = NULL;
	}
	RAGEL_WRITE_INIT_PREP(MAX_MARKER);
	%% write init;
}

void jsonParserParserExec(JSONParser parser, ExecPrivateBlockData *data)
{
	RAGEL_WRITE_EXEC_IN();
	%% write exec;
	RAGEL_WRITE_EXEC_OUT();
}

// private functions

bool jsonParserBuildAddElement(JSONParser parser)
{
	bool error = false;
	if (parserConfig.buildAddElement) {
		JSONParserValue value = emptyJSONParserValue;
		value.type = parserValue.type;
		value.item = parserStack.item[parserTop];
		switch ((int)parserValue.type) {
			case JSON_PARSER_VALUE_TYPE_STRING:
				value.string = parserValue.string ? parserValue.string : "";
				break;
			case JSON_PARSER_VALUE_TYPE_NUMBER:
				value.number = strtod(parserValue.numberString, NULL);
				value.string = parserValue.numberString;
				break;
		}
		void *item = parserStack.item[parserTop - 1];
		if (!parserConfig.buildAddElement(parserUserData, item, &value)) {
			parserError = JSON_PARSER_ERROR_MEMORY;
			error = true;
		}
	}
	if (parserTop > 1 && parserStack.name[parserTop - 1]) {
		jsonParserStringFree(parserStack.name[parserTop - 1]);
		parserStack.name[parserTop - 1] = NULL;
	}
	if (parserValue.string) {
		jsonParserStringFree(parserValue.string);
		parserValue.string = NULL;
	}
	return !error;
}

bool jsonParserBuildNewItem(JSONParser parser)
{
	bool error = false;
	if (parserTop < MAX_PSTACK) {
		JSONParserValue value = emptyJSONParserValue;
		value.type = parserValue.type;
		if (parserConfig.buildNewItem) {
			if (!parserConfig.buildNewItem(parserUserData, &value/*, parserTop*/)) {
				parserError = JSON_PARSER_ERROR_MEMORY;
				error = true;
			}
		}
		parserStack.item[parserTop++] = value.item;
	} else {
		parserError = JSON_PARSER_ERROR_PSTACK;
		error = true;
	}
	return !error;
}

bool jsonParserBuildSetMember(JSONParser parser)
{
	bool error = false;
	if (parserConfig.buildSetMember) {
		JSONParserValue value = emptyJSONParserValue;
		value.type = parserValue.type;
		value.item = parserStack.item[parserTop];
		switch ((int)parserValue.type) {
			case JSON_PARSER_VALUE_TYPE_STRING:
				value.string = parserValue.string ? parserValue.string : "";
				break;
			case JSON_PARSER_VALUE_TYPE_NUMBER:
				value.number = strtod(parserValue.numberString, NULL);
				value.string = parserValue.numberString;
				break;
		}
		void *item = parserStack.item[parserTop - 1];
		char *name = parserStack.name[parserTop - 1];
		if (!parserConfig.buildSetMember(parserUserData, item, name, &value)) {
			parserError = JSON_PARSER_ERROR_MEMORY;
			error = true;
		}
	}
	if (parserTop > 1 && parserStack.name[parserTop - 1]) {
		jsonParserStringFree(parserStack.name[parserTop - 1]);
		parserStack.name[parserTop - 1] = NULL;
	}
	if (parserValue.string) {
		jsonParserStringFree(parserValue.string);
		parserValue.string = NULL;
	}
	return !error;
}

/* Tokyo Cabinet's tcstrucstoutf in tcutil.c.
   Convert a UCS-2 array into a UTF-8 string. */
int jsonParserUCS2ToUTF8(const uint16_t *ary, int num, char *str)
{
	assert(ary && num >= 0 && str);
	unsigned char *wp = (unsigned char *)str;
	for (int i = 0; i < num; i++) {
		unsigned int c = ary[i];
		if (c < 0x80) {
			*(wp++) = c;
		} else if (c < 0x800) {
			*(wp++) = 0xc0 | (c >> 6);
			*(wp++) = 0x80 | (c & 0x3f);
		} else {
			*(wp++) = 0xe0 | (c >> 12);
			*(wp++) = 0x80 | ((c & 0xfff) >> 6);
			*(wp++) = 0x80 | (c & 0x3f);
		}
	}
	*wp = '\0';
	return (char *)wp - str;
}

bool jsonParserValueString(JSONParser parser, const char *data, size_t size)
{
	bool error = false;
	parserValue.string = jsonParserStringAppend(parserValue.string, data, size);
	if (parserValue.string == NULL) {
		parserError = JSON_PARSER_ERROR_MEMORY;
		error = true;
	}
	return !error;
}

bool jsonParserWriteArrayElement(JSONParser parser)
{
	bool error = false;
	if (parserValue.type != JSON_PARSER_VALUE_TYPE_ARRAY && parserValue.type != JSON_PARSER_VALUE_TYPE_OBJECT) {
		if (parserConfig.writeArrayElement) {
			JSONParserValue value = emptyJSONParserValue;
			//
			value.type = parserValue.type;
			switch ((int)parserValue.type) {
				case JSON_PARSER_VALUE_TYPE_STRING:
					value.string = parserValue.string ? parserValue.string : "";
					break;
				case JSON_PARSER_VALUE_TYPE_NUMBER:
					value.number = strtod(parserValue.numberString, NULL);
					value.string = parserValue.numberString;
					break;
			}
			//
			if (!parserConfig.writeArrayElement(parserUserData, &value)) {
				parserError = JSON_PARSER_ERROR_WRITER;
				error = true;
			}
		}
	}
	return !error;
}

bool jsonParserWriteObjectMember(JSONParser parser)
{
	bool error = false;
	if (parserValue.type != JSON_PARSER_VALUE_TYPE_ARRAY && parserValue.type != JSON_PARSER_VALUE_TYPE_OBJECT) {
		if (parserConfig.writeObjectMember) {
			char *name = parserStack.name[parserTop - 1];
			JSONParserValue value = emptyJSONParserValue;
			//
			value.type = parserValue.type;
			switch ((int)parserValue.type) {
				case JSON_PARSER_VALUE_TYPE_STRING:
					value.string = parserValue.string ? parserValue.string : "";
					break;
				case JSON_PARSER_VALUE_TYPE_NUMBER:
					value.number = strtod(parserValue.numberString, NULL);
					value.string = parserValue.numberString;
					break;
			}
			//
			if (!parserConfig.writeObjectMember(parserUserData, name, &value)) {
				parserError = JSON_PARSER_ERROR_WRITER;
				error = true;
			}
		}
	}
	return !error;
}

bool jsonParserWriteStart(JSONParser parser)
{
	bool error = false;
	if (parserConfig.writeStart) {
		if (!parserConfig.writeStart(parserUserData)) {
			parserError = JSON_PARSER_ERROR_WRITER;
			error = true;
		}
	}
	return !error;
}

bool jsonParserWriteStartArray(JSONParser parser)
{
	bool error = false;
	if (parserConfig.writeStartArray) {
		char *name = parserStack.name[parserTop - 1];
		if (!parserConfig.writeStartArray(parserUserData, name)) {
			parserError = JSON_PARSER_ERROR_WRITER;
			error = true;
		}
	}
	return !error;
}

bool jsonParserWriteStartObject(JSONParser parser)
{
	bool error = false;
	if (parserConfig.writeStartObject) {
		char *name = parserStack.name[parserTop - 1];
		if (!parserConfig.writeStartObject(parserUserData, name)) {
			parserError = JSON_PARSER_ERROR_WRITER;
			error = true;
		}
	}
	return !error;
}

bool jsonParserWriteStop(JSONParser parser)
{
	bool error = false;
	if (parserConfig.writeStop) {
		if (!parserConfig.writeStop(parserUserData)) {
			parserError = JSON_PARSER_ERROR_WRITER;
			error = true;
		}
	}
	return !error;
}

bool jsonParserWriteStopArray(JSONParser parser)
{
	bool error = false;
	if (parserConfig.writeStopArray) {
		if (!parserConfig.writeStopArray(parserUserData)) {
			parserError = JSON_PARSER_ERROR_WRITER;
			error = true;
		}
	}
	return !error;
}

bool jsonParserWriteStopObject(JSONParser parser)
{
	bool error = false;
	if (parserConfig.writeStopObject) {
		if (!parserConfig.writeStopObject(parserUserData)) {
			parserError = JSON_PARSER_ERROR_WRITER;
			error = true;
		}
	}
	return !error;
}

// public functions

//======================================================================
//
// Spec:	JSON Parser API
//
//----------------------------------------------------------------------
//
// Func:	createJSONParser => JSONParser JSONPARSERAPI createJSONParser(JSONParserConfig *config)
//			Create a new ##parser## object. The parser must be freed with ##[[#|jsonParserFree]]## when no longer needed.
//
// Param:	config => JSONParserConfig *
//			(optional) The config object. If the value is NULL the standard ##emptyJSONParserConfig## config is used. 
//			With ##emptyJSONParserConfig## all options are set to ##false## and the callbacks set to ##NULL##.
//
// Return:	parser => JSONParser
//			The new parser object. Note: The value will be ##NULL## if memory could not be allocated.
//

JSONParser JSONPARSERAPI createJSONParser(JSONParserConfig *config)
{
	JSONParser parser = malloc(sizeof(JSONParserParser));
	if (parser) {
		parserUserData = NULL;
		parserConfig = config ? *config : emptyJSONParserConfig;
		parserCurrentLine = 0;
		parserError = 0;
	}
	return parser;
}

//----------------------------------------------------------------------
//
// Func:	createJSONParserBuffer => JSONParserBuffer JSONPARSERAPI *createJSONParserBuffer(size_t size)
//			Create a new ##buffer## object. The buffer must be freed with ##[[#|jsonParserBufferFree]]## when no longer needed.
//
// Param:	size => size_t
//			The buffer size.
//
// Return:	buffer => JSONParserBuffer *
//			The new buffer object. Note: The value will be ##NULL## if memory could not be allocated.
//

JSONParserBuffer JSONPARSERAPI *createJSONParserBuffer(size_t size)
{
	if (size <= 0) size = JSON_PARSER_BUFFER_SIZE;
	JSONParserBuffer *buffer = malloc(sizeof(JSONParserBufferPtr) + size + 1);
	if (buffer) {
		buffer->data = (const char *)(buffer + sizeof(JSONParserBufferPtr));
		((char *)buffer->data)[size] = '\0';
		buffer->size = size;
	}
	return buffer;
}

//----------------------------------------------------------------------
//
// Func:	createJSONParserString => char JSONPARSERAPI *createJSONParserString(const char *data, size_t size)
//			Create a new ##string## object with text. The string must be freed with ##[[#|jsonParserStringFree]]## when no longer needed.
//
// Param:	data => const char *
//			The text buffer data.
//
// Param:	size => size_t
//			The text buffer size.
//
// Return:	string => char *
//			The new string object. Note: The value will be ##NULL## if memory could not be allocated.
//

char JSONPARSERAPI *createJSONParserString(const char *data, size_t size)
{
	assert(data);
	assert(size >= 0);
	char *string = malloc(size + 1);
	if (string) {
		#if !defined(NDEBUG)
		g_jsonParserStringCounter++;
		#endif
		strncpy(string, data, size);
		string[size] = '\0';
	}
	return string;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserBufferFree => void JSONPARSERAPI jsonParserBufferFree(JSONParserBuffer *buffer)
//			Free the memory allocated to ##buffer##. The buffer must be a valid buffer created with an earlier 
//			call to [[#|createJSONParserBuffer]]. The buffer value must not be used after it is freed. It 
//			is good practice to set the buffer value to ##NULL## after calling this function.
//
// Param:	buffer => JSONParserBuffer *
//			The buffer to be freed.
//
// Return:	none => void
//

void JSONPARSERAPI jsonParserBufferFree(JSONParserBuffer *buffer)
{
	assert(buffer);
	free(buffer);
}

//----------------------------------------------------------------------
//
// Func:	jsonParserConfigureBuilders => void JSONPARSERAPI jsonParserConfigureBuilders(JSONParser parser, BuildAddElementFunc buildAddElement, BuildNewItemFunc buildNewItem, BuildSetMemberFunc buildSetMember)
//			Configure the builder callbacks for the parser. These callbacks are applied to a copy of the original config 
//			object (if any) which was passed in the call to [[#|createJSONParser]]. The original config object remains unchanged.
//			
//			The builder callback functions are declared as follows:
//			
//			{{{
//			typedef bool (*BuildAddElementFunc)(void *userData, void *item, JSONParserValue *value);
//			typedef bool (*BuildNewItemFunc)(void *userData, JSONParserValue *value/*, int depth*/);
//			typedef bool (*BuildSetMemberFunc)(void *userData, void *item, char *name, JSONParserValue *value);
//			}}}
//			
//			Return ##true## on success and ##false## on failure. Record any specific error details in ##userData## if they are needed.
//			
//			Note: Parser stack overflow (##JSON_PARSER_ERROR_PSTACK##) is a product of the builder functions. If support for builder functions is removed then the stack issues will also go away.
//
// Param:	parser => JSONParser
//			The parser object.
//
// Param:	buildAddElement => BuildAddElementFunc
//			Builder callback to add an element to the array item.
//
// Param:	buildNewItem => BuildNewItemFunc
//			Builder callback to make a new array or object item.
//
// Param:	buildSetMember => BuildSetMemberFunc
//			Builder callback to set a member of the object item.
//
// Return:	none => void
//

void JSONPARSERAPI jsonParserConfigureBuilders(JSONParser parser, BuildAddElementFunc buildAddElement, 
		BuildNewItemFunc buildNewItem, BuildSetMemberFunc buildSetMember)
{
 	assert(parser);
 	parserConfig.buildAddElement = buildAddElement;
 	parserConfig.buildNewItem = buildNewItem;
 	parserConfig.buildSetMember = buildSetMember;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserConfigureWriters => void JSONPARSERAPI jsonParserConfigureWriters(JSONParser parser, WriteArrayElementFunc writeArrayElement, WriteObjectMemberFunc writeObjectMember, WriteStartFunc writeStart, WriteStartArrayFunc writeStartArray, WriteStartObjectFunc writeStartObject, WriteStopFunc writeStop, WriteStopArrayFunc writeStopArray, WriteStopObjectFunc writeStopObject)
//			Configure the writer callbacks for the parser. These callbacks are applied to a copy of the original config 
//			object (if any) which was passed in the call to [[#|createJSONParser]]. The original config object remains unchanged.
//			
//			The writer callback functions are declared as follows:
//			
//			{{{
//			typedef bool (*WriteArrayElementFunc)(void *userData, JSONParserValue *value);
//			typedef bool (*WriteObjectMemberFunc)(void *userData, char *name, JSONParserValue *value);
//			typedef bool (*WriteStartFunc)(void *userData);
//			typedef bool (*WriteStartArrayFunc)(void *userData, char *name);
//			typedef bool (*WriteStartObjectFunc)(void *userData, char *name);
//			typedef bool (*WriteStopFunc)(void *userData);
//			typedef bool (*WriteStopArrayFunc)(void *userData);
//			typedef bool (*WriteStopObjectFunc)(void *userData);
//			}}}
//			
//			Return ##true## on success and ##false## on failure. Record any specific error details in ##userData## if they are needed.
//
// Param:	parser => JSONParser
//			The parser object.
//
// Param:	writeArrayElement => WriteArrayElementFunc
//			Writer callback to add an element to the array context. Primitive values only, array and object values are handled separately.
//
// Param:	writeObjectMember => WriteObjectMemberFunc
//			Writer callback to set a member of the object context. Primitive values only, array and object values are handled separately.
//
// Param:	writeStart => WriteStartFunc
//			Writer callback to initialize the document context.
//
// Param:	writeStartArray => WriteStartArrayFunc
//			Writer callback to push a new array context. If the ##name## parameter is ##NULL## the parent context is an array, otherwise it is an object.
//
// Param:	writeStartObject => WriteStartObjectFunc
//			Writer callback to push a new object context. If the ##name## parameter is ##NULL## the parent context is an array, otherwise it is an object.
//
// Param:	writeStop => WriteStopFunc
//			Writer callback to terminate the document context.
//
// Param:	writeStopArray => WriteStopArrayFunc
//			Writer callback to pop the array and restore the parent context.
//
// Param:	writeStopObject => WriteStopObjectFunc
//			Writer callback to pop the object and restore the parent context.
//
// Return:	none => void
//

void JSONPARSERAPI jsonParserConfigureWriters(JSONParser parser, 
		WriteArrayElementFunc writeArrayElement, WriteObjectMemberFunc writeObjectMember, 
		WriteStartFunc writeStart, WriteStartArrayFunc writeStartArray, WriteStartObjectFunc writeStartObject, 
		WriteStopFunc writeStop, WriteStopArrayFunc writeStopArray, WriteStopObjectFunc writeStopObject)
{
 	assert(parser);
 	parserConfig.writeArrayElement = writeArrayElement;
 	parserConfig.writeObjectMember = writeObjectMember;
 	parserConfig.writeStart = writeStart;
 	parserConfig.writeStartArray = writeStartArray;
 	parserConfig.writeStartObject = writeStartObject;
 	parserConfig.writeStop = writeStop;
 	parserConfig.writeStopArray = writeStopArray;
 	parserConfig.writeStopObject = writeStopObject;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserFree => void JSONPARSERAPI jsonParserFree(JSONParser parser)
//			Free the memory allocated to ##parser##. The parser must be a valid parser created with an earlier 
//			call to [[#|createJSONParser]]. The parser value must not be used after it is freed. It 
//			is good practice to set the parser value to ##NULL## after calling this function.
//
// Param:	parser => JSONParser
//			The parser to be freed.
//
// Return:	none => void
//

void JSONPARSERAPI jsonParserFree(JSONParser parser)
{
	assert(parser);
	free(parser);
}

//----------------------------------------------------------------------
//
// Func:	jsonParserGetCurrentLine => int JSONPARSERAPI jsonParserGetCurrentLine(JSONParser parser)
//			Return the current line of the parser. Line numbers start from ##1## and continue to the end of the document. 
//			Before the parser has started the value will be ##0##, on completion the value will be the total number of 
//			lines in the document. When an error occurs the value will be the line the error occurred on.
//
// Param:	parser => JSONParser
//			The parser object.
//
// Return:	value => int
//			The current line.
//

int JSONPARSERAPI jsonParserGetCurrentLine(JSONParser parser)
{
	assert(parser);
	return parserCurrentLine;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserGetErrorCode => enum JSON_PARSER_ERROR JSONPARSERAPI jsonParserGetErrorCode(JSONParser parser)
//			Return the error code of the parser. The error code is set when an error occurs during parsing.
//			Errors which occur during reading or writing are caught in the parser and returned as 
//			##JSON_PARSER_ERROR_READER## and ##JSON_PARSER_ERROR_WRITER## respectively. Readers and writers
//			should record any specific error details in ##userData## if they are needed. The ##JSON_PARSER_ERROR_PARSER##
//			error indicates a syntax error, ##JSON_PARSER_ERROR_MEMORY## indicates an out of memory error, 
//			##JSON_PARSER_ERROR_BUFFER## indicates a token in the stream was too big for the user supplied buffer.
//			
//			|= Errors                       |= Description                       |
//			| ##JSON_PARSER_ERROR_UNKNOWN## | An unknown error occurred.         |
//			| ##JSON_PARSER_ERROR_NONE##    | No error.                          |
//			| ##JSON_PARSER_ERROR_BUFFER##  | Token too big for buffer.          |
//			| ##JSON_PARSER_ERROR_MEMORY##  | An out of memory error occurred.   |
//			| ##JSON_PARSER_ERROR_PARSER##  | Input could not be parsed.         |
//			| ##JSON_PARSER_ERROR_PSTACK##  | Parser stack overflow.             |
//			| ##JSON_PARSER_ERROR_READER##  | An error occurred with the reader. |
//			| ##JSON_PARSER_ERROR_WRITER##  | An error occurred with the writer. |
//			
//			The ##JSON_PARSER_ERROR_NONE## error is equal to ##0##, ##JSON_PARSER_ERROR_UNKNOWN## is less than ##0##, 
//			all other errors are greater than ##0##.
//
// Param:	parser => JSONParser
//			The parser object.
//
// Return:	value => enum JSON_PARSER_ERROR
//			The error code.
//

enum JSON_PARSER_ERROR JSONPARSERAPI jsonParserGetErrorCode(JSONParser parser)
{
	assert(parser);
	return parserError;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserGetErrorString => const char JSONPARSERAPI *jsonParserGetErrorString(JSONParser parser)
//			Return the error string associated with the error code of the parser. See ##[[#|jsonParserGetErrorCode]] for details.
//
// Param:	parser => JSONParser
//			The parser object.
//
// Return:	value => const char *
//			The error string.

const char JSONPARSERAPI *jsonParserGetErrorString(JSONParser parser)
{
	assert(parser);
	switch (parserError) {
		case JSON_PARSER_ERROR_NONE:
			return "JSON_PARSER_ERROR_NONE";
		case JSON_PARSER_ERROR_UNKNOWN:
			return "JSON_PARSER_ERROR_UNKNOWN";
		case JSON_PARSER_ERROR_BUFFER:
			return "JSON_PARSER_ERROR_BUFFER";
		case JSON_PARSER_ERROR_MEMORY:
			return "JSON_PARSER_ERROR_MEMORY";
		case JSON_PARSER_ERROR_PARSER:
			return "JSON_PARSER_ERROR_PARSER";
		case JSON_PARSER_ERROR_PSTACK:
			return "JSON_PARSER_ERROR_PSTACK";
		case JSON_PARSER_ERROR_READER:
			return "JSON_PARSER_ERROR_READER";
		case JSON_PARSER_ERROR_WRITER:
			return "JSON_PARSER_ERROR_WRITER";
		default:
			return NULL;
	}
}

//----------------------------------------------------------------------
//
// Func:	jsonParserGetUserData => void JSONPARSERAPI *jsonParserGetUserData(JSONParser parser)
//			Return user data associated with the parser in an earlier call to ##[[#|jsonParserSetUserData]]##. 
//			The ##void *userData## should be recast to use. Callback functions are provided the same ##void *userData##. 
//			Macros can make using the user data easier, for example:
//			
//			{{{
//			#define userDataRowCount (((JSON2HTMLUserDataPtr)userData)->rowCount)
//			}}}
//
// Param:	parser => JSONParser
//			The parser object.
//
// Return:	value => void *
//			The user data.
//

/* #define jsonParserGetUserData(parser) (*(void **)(parser)) */

//----------------------------------------------------------------------
//
// Func:	jsonParserParseStream => bool JSONPARSERAPI jsonParserParseStream(JSONParser parser, JSONParserBuffer *buffer, ReaderFunc reader, void *item, char *name)
//			Parse the reader input. Callbacks are used to build the JSON array/elements and object/members parse tree.
//			
//			The ##ReaderFunc## reader callback is declared as follows:
//			
//			{{{
//			typedef bool (*ReaderFunc)(void *userData, JSONParserBuffer *buffer, size_t *size);
//			
//			bool jsonParserStandardInputReader(void *userData, JSONParserBuffer *buffer, size_t *size) {
//			    *size = fread((char *)buffer->data, 1, buffer->size, stdin);
//			    return ferror(stdin) == 0;
//			}
//			}}}
//			
//			Return ##true## on success and ##false## on failure. Record any specific error details in ##userData## if they are needed.
//
// Param:	parser => JSONParser
//			The parser object.
//
// Param:	buffer => JSONParserBufferPtr
//			The buffer for the parser. Buffer management functions are performed automatically.
//
// Param:	reader => ReaderFunc
//			(optional) The parser calls this functions whenever it needs to fill the buffer. If the value 
//			is NULL the default ##[[#|jsonParserStandardInputReader]]## callback function is used.
//
// Param:	item => void *
//			The root object for the parse value (i.e. the top most result of the parse).
//
// Param:	name => char *
//			(optional) The member name in the root object. If the value is NULL the default name "##root##" is used.
//
// Return:	success => bool
//			Returns ##true## on success and ##false## on failure. Call the ##[[#|jsonParserGetErrorCode]]## 
//			and ##[[#|jsonParserGetErrorString]]## functions for information about the failure.
//			Possible errors include: ##JSON_PARSER_ERROR_BUFFER##, ##JSON_PARSER_ERROR_MEMORY##, 
//			##JSON_PARSER_ERROR_PARSER##, ##JSON_PARSER_ERROR_PSTACK##, and ##JSON_PARSER_ERROR_READER##.
//

bool JSONPARSERAPI jsonParserParseStream(JSONParser parser, JSONParserBuffer *buffer, ReaderFunc reader, void *item, char *name)
{
	assert(parser);
	assert(buffer);
	bool error = false;
	jsonParserParserInit(parser, item, name);
	if (!reader) reader = jsonParserStandardInputReader;
	RAGEL_PARSE_STREAM(jsonParserParserExec, JSONParser, JSON_PARSER_ERROR, MAX_MARKER);
	return !error;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserParseString => bool JSONPARSERAPI jsonParserParseString(JSONParser parser, char *string, void *item, char *name)
//			Parse the string. Callbacks are used to build the JSON array/elements and object/members parse tree.
//
// Param:	parser => JSONParser
//			The parser object.
//
// Param:	string => char *
//			The string to parse.
//
// Param:	item => void *
//			The root object for the parse value (i.e. the top most result of the parse).
//
// Param:	name => char *
//			(optional) The member name in the root object. If the value is NULL the default name "##root##" is used.
//
// Return:	success => bool
//			Returns ##true## on success and ##false## on failure. Call the ##[[#|jsonParserGetErrorCode]]## and 
//			##[[#|jsonParserGetErrorString]]## functions for information about the failure.
//			Possible errors include: ##JSON_PARSER_ERROR_MEMORY##, 
//			##JSON_PARSER_ERROR_PARSER##, and ##JSON_PARSER_ERROR_PSTACK##.
//

bool JSONPARSERAPI jsonParserParseString(JSONParser parser, char *string, void *item, char *name)
{
	assert(parser);
	assert(string);
	bool error = false;
	jsonParserParserInit(parser, item, name);
	RAGEL_PARSE_STRING(jsonParserParserExec, JSONParser, JSON_PARSER_ERROR, MAX_MARKER);
	return !error;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserSetUserData => void JSONPARSERAPI *jsonParserSetUserData(JSONParser parser, void *userData)
//			Associate user data with the parser for callback functions. See also ##[[#|jsonParserGetUserData]]##.
//
// Param:	parser => JSONParser
//			The parser object.
//
// Param:	userData => void *
//			The user data.
//
// Return:	none => void
//

void JSONPARSERAPI *jsonParserSetUserData(JSONParser parser, void *userData)
{
	assert(parser);
	void *previous = parserUserData;
	parserUserData = userData;
	return previous;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserStandardInputReader => bool jsonParserStandardInputReader(void *userData, JSONParserBuffer *buffer, size_t *size)
//			The default reader callback for filling the buffer with ##stdin##. See also ##[[#|jsonParserParseStream]]##.
//
// Param:	userData => void *
//			The user data associated with the parser.
//
// Param:	buffer => JSONParserBuffer *
//			The buffer to read into.
//
// Param:	size => size_t *
//			Pointer for returning the amount of bytes read into the buffer.
//
// Return:	success => bool
//			Returns ##true## on success and ##false## on failure. No specific error details are recorded for ##JSON_PARSER_ERROR_READER##.
//

bool jsonParserStandardInputReader(void *userData, JSONParserBuffer *buffer, size_t *size) {
	*size = fread((char *)buffer->data, 1, buffer->size, stdin);
	return ferror(stdin) == 0;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserStringAppend => char JSONPARSERAPI *jsonParserStringAppend(char *string, const char *data, size_t size)
//			Append text to ##string##. The string must be a valid string created with an earlier call to [[#|createJSONParserString]].
//			The string must be freed with ##[[#|jsonParserStringFree]]## when no longer needed.
//
// Param:	string => char *
//			(optional) The string object. If the value is NULL a new string will be created.
//
// Param:	data => const char *
//			The text buffer data.
//
// Param:	size => size_t
//			The text buffer size.
//
// Return:	string => char *
//			The (possibly) new string object. Note: The value will be ##NULL## if memory could not be allocated.
//

char JSONPARSERAPI *jsonParserStringAppend(char *string, const char *data, size_t size)
{
	assert(data);
	assert(size >= 0);
	char *pointer = string;
	size_t current = pointer ? strlen(pointer) : 0;
	string = realloc(pointer, current + size + 1);
	if (string) {
		#if !defined(NDEBUG)
		if (!pointer) g_jsonParserStringCounter++;
		#endif
		strncpy(string + current, data, size);
		string[current + size] = '\0';
	}
	return string;
}

//----------------------------------------------------------------------
//
// Func:	jsonParserStringFree => void JSONPARSERAPI jsonParserStringFree(char *string)
//			Free the memory allocated to ##string##. The string must be a valid string created with an earlier 
//			call to [[#|createJSONParserString]]. The string value must not be used after it is freed. It 
//			is good practice to set the string value to ##NULL## after calling this function.
//
// Param:	string => char *
//			The string to be freed.
//
// Return:	none => void
//

void JSONPARSERAPI jsonParserStringFree(char *string)
{
	assert(string);
	#if !defined(NDEBUG)
	g_jsonParserStringCounter--;
	#endif
	free(string);
}

//======================================================================
//
// Topic:	Release Notes
//			<<<include:release-notes>>>
//

/* END OF FILE */
