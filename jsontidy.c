/* gcc -I/usr/local/include jsontidy.c -o jsontidy -L/usr/local/lib -ljsonparser */
/* ./jsontidy -i 4 < example.json */

#include <jsonparser.h>
#include <assert.h>
#include <unistd.h>

typedef struct UserDataStruct {
	int depth;
	int indent;
} UserData, *UserDataPtr;

#define userDataDepth (((UserDataPtr)userData)->depth)
#define userDataIndent (((UserDataPtr)userData)->indent)

char *jsonTypes[] = { NULL, "string", "number", "{}", "[]", "true", "false", "null" };

bool writeArrayElement(void *userData, JSONParserValue *value)
{
	char *elementValue = value->string; /* string and number */
	elementValue = elementValue ? elementValue : jsonTypes[value->type];
	return fprintf(stdout, "%*s\n", (userDataDepth + 1) * userDataIndent, elementValue) > 0;
}

bool writeObjectMember(void *userData, char *name, JSONParserValue *value)
{
	char *memberValue = value->string; /* string and number */
	memberValue = memberValue ? memberValue : jsonTypes[value->type];
	return fprintf(stdout, "%*s = %s\n", (userDataDepth + 1) * userDataIndent, name, memberValue) > 0;
}

bool writeStart(void *userData)
{
	/* userDataContext = newDocument(); */
	userDataDepth = 0;
	return true;
}

bool writeStartArray(void *userData, char *name)
{
	/* userDataContext = addChild(userDataContext, newArray(), name); */
	if (name && userDataDepth) {
		fprintf(stdout, "%*s = %s\n", (userDataDepth + 1) * userDataIndent, name, "[");
	} else {
		fprintf(stdout, "%*s\n", userDataDepth * userDataIndent, "[");
	}
	userDataDepth++;
	return true;
}

bool writeStartObject(void *userData, char *name)
{
	/* userDataContext = addChild(userDataContext, newObject(), name); */
	if (name && userDataDepth) {
		fprintf(stdout, "%*s = %s\n", (userDataDepth + 1) * userDataIndent, name, "{");
	} else {
		fprintf(stdout, "%*s\n", userDataDepth * userDataIndent, "{");
	}
	userDataDepth++;
	return true;
}

bool writeStop(void *userData)
{
	assert(userDataDepth == 0);
	return true;
}

bool writeStopArray(void *userData)
{
	/* userDataContext = getParent(userDataContext); */
	userDataDepth--;
	fprintf(stdout, "%*s\n", userDataDepth * userDataIndent, "]");
	return true;
}

bool writeStopObject(void *userData)
{
	/* userDataContext = getParent(userDataContext); */
	userDataDepth--;
	fprintf(stdout, "%*s\n", userDataDepth * userDataIndent, "}");
	return true;
}

int main(int argc, char **argv)
{
	char *ivalue = NULL;
	int c;
	while ((c = getopt(argc, argv, "i:")) != -1) {
		switch (c) {
			case 'i': /* Indentation. */
				ivalue = optarg;
				break;
			case '?':
				/* fall through */
			default:
				fprintf(stderr, "Usage: %s [-i indent]\n", argv[0]);
				return 1;
		}
	}
	JSONParserConfig config = {
		NULL, NULL, NULL, 
		writeArrayElement, writeObjectMember, 
		writeStart, writeStartArray, writeStartObject, 
		writeStop, writeStopArray, writeStopObject
	};
	JSONParser parser = createJSONParser(&config);
	if (parser) {
		UserData userData = { 0, ivalue ? atoi(ivalue) : 8 };
		jsonParserSetUserData(parser, &userData);
		JSONParserBuffer *buffer = createJSONParserBuffer(JSON_PARSER_BUFFER_SIZE);
		if (buffer) {
			if (!jsonParserParseStream(parser, buffer, NULL, NULL, NULL)) {
			fprintf(stderr, "Error: parser error: %d %s (line %d)\n", 
					jsonParserGetErrorCode(parser), jsonParserGetErrorString(parser), 
					jsonParserGetCurrentLine(parser));
				return 1;
			}
			jsonParserBufferFree(buffer);
			buffer = NULL;
		} else {
			fprintf(stderr, "Error: could not allocate buffer: %lld\n", (long long)buffer->size);
			return 1;
		}
		jsonParserFree(parser);
		parser = NULL;
	} else {
		fprintf(stderr, "Error: could not create parser\n");
		return 1;
	}
	return 0;
}
