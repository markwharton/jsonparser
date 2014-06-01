#include <jsonparser.h>
#include <assert.h>
#include <tcutil.h>
#include <unistd.h>

#define _TCTYPRFXLIST "[list]\0:"		/* type prefix for a list object */
#define _TCTYPRFXMAP "[map]\0:"			/* type prefix for a map object */

TCLIST *_tcmapgetlist(TCMAP *map, const char *kstr);
TCMAP *_tcmapgetmap(TCMAP *map, const char *kstr);

bool jsonAddElement(void *userData, void *item, JSONParserValue *value)
{
	TCLIST *array = (TCLIST *)item;
	switch ((int)value->type) {
		case JSON_PARSER_VALUE_TYPE_STRING:
			tclistpush2(array, value->string);
			break;
		case JSON_PARSER_VALUE_TYPE_NUMBER:
			tclistpush2(array, value->string); /* value->number for double */
			break;
		case JSON_PARSER_VALUE_TYPE_OBJECT:
			tclistpushmap(array, value->item);
			break;
		case JSON_PARSER_VALUE_TYPE_ARRAY:
			tclistpushlist(array, value->item);
			break;
		case JSON_PARSER_VALUE_TYPE_TRUE:
			tclistpush2(array, "true");
			break;
		case JSON_PARSER_VALUE_TYPE_FALSE:
			tclistpush2(array, "false");
			break;
		case JSON_PARSER_VALUE_TYPE_NULL:
			tclistpush2(array, "null");
			break;
	}
	return true;
}

bool jsonNewItem(void *userData, JSONParserValue *value/*, int depth*/)
{
	TCMPOOL *mpool = (TCMPOOL *)userData;
	switch ((int)value->type) {
		case JSON_PARSER_VALUE_TYPE_OBJECT:
			value->item = tcmpoolmapnew(mpool);
			break;
		case JSON_PARSER_VALUE_TYPE_ARRAY:
			value->item = tcmpoollistnew(mpool);
			break;
	}
	return true;
}

bool jsonSetMember(void *userData, void *item, char *name, JSONParserValue *value)
{
	TCMAP *object = (TCMAP *)item;
	switch ((int)value->type) {
		case JSON_PARSER_VALUE_TYPE_STRING:
			tcmapput2(object, name, value->string);
			break;
		case JSON_PARSER_VALUE_TYPE_NUMBER:
			tcmapput2(object, name, value->string); /* value->number for double */
			break;
		case JSON_PARSER_VALUE_TYPE_OBJECT:
			tcmapputmap(object, name, value->item);
			break;
		case JSON_PARSER_VALUE_TYPE_ARRAY:
			tcmapputlist(object, name, value->item);
			break;
		case JSON_PARSER_VALUE_TYPE_TRUE:
			tcmapput2(object, name, "true");
			break;
		case JSON_PARSER_VALUE_TYPE_FALSE:
			tcmapput2(object, name, "false");
			break;
		case JSON_PARSER_VALUE_TYPE_NULL:
			tcmapput2(object, name, "null");
			break;
	}
	return true;
}

/* Retrieve a list object from a map object with the type information. */
TCLIST *_tcmapgetlist(TCMAP *map, const char *kstr) {
	int vsiz;
	TCLIST *obj = NULL;
	const char *vbuf = tcmapget(map, kstr, strlen(kstr), &vsiz);
	if (vbuf && vsiz == sizeof(_TCTYPRFXLIST) - 1 + sizeof(TCLIST *) && !memcmp(vbuf, _TCTYPRFXLIST, sizeof(_TCTYPRFXLIST) - 1)) {
		memcpy(&obj, vbuf + sizeof(_TCTYPRFXLIST) - 1, sizeof(obj));
	}
	return obj;
}

/* Retrieve a map object from a map object with the type information. */
TCMAP *_tcmapgetmap(TCMAP *map, const char *kstr) {
	int vsiz;
	TCMAP *obj = NULL;
	const char *vbuf = tcmapget(map, kstr, strlen(kstr), &vsiz);
	if (vbuf && vsiz == sizeof(_TCTYPRFXMAP) - 1 + sizeof(TCMAP *) && !memcmp(vbuf, _TCTYPRFXMAP, sizeof(_TCTYPRFXMAP) - 1)) {
		memcpy(&obj, vbuf + sizeof(_TCTYPRFXMAP) - 1, sizeof(obj));
	}
	return obj;
}

int main(int argc, char **argv)
{
	char *bvalue = NULL;
	int c;
	while ((c = getopt(argc, argv, "b:")) != -1) {
		switch (c) {
			case 'b': /* Input stream buffer size for testing. */
				bvalue = optarg;
				break;
			case '?':
				/* fall through */
			default:
				fprintf(stderr, "Usage: %s [-b bufferSize]\n", argv[0]);
				return 1;
		}
	}
	TCMPOOL *mpool = tcmpoolnew(); // will exit if no memory
	TCMAP *object = tcmpoolmapnew(mpool); // will exit if no memory
	JSONParserConfig config = { jsonAddElement, jsonNewItem, jsonSetMember };
	JSONParser parser = createJSONParser(&config);
	if (parser) {
		jsonParserSetUserData(parser, mpool);
		size_t size = bvalue ? atoi(bvalue) : JSON_PARSER_BUFFER_SIZE;
		JSONParserBuffer *buffer = createJSONParserBuffer(size);
		if (buffer) {
			if (!jsonParserParseStream(parser, buffer, NULL, object, "root")) {
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
	#if !defined(NDEBUG)
	printf("STRINGS REMAINING: %d\n", g_jsonParserStringCounter);
	#endif
	TCTMPL *tmpl = tcmpoolpush(mpool, tctmplnew(), (void (*)(void *))tctmpldel);
	char *path = tcmpoolpushptr(mpool, tcsprintf("%s.tmpl", argv[0]));
	if (tctmplload2(tmpl, path)) {
		char *str = tcmpoolpushptr(mpool, tctmpldump(tmpl, object));
		if (str) printf("%s", str);
	} else {
		fprintf(stderr, "The template file is missing. (%s)\n", path);
	}
	if (false) { // for testing
		TCMAP *map = _tcmapgetmap(object, "root");
		if (map) {
			fprintf(stdout, "root object members >>>\n");
			TCLIST *list = tcmapkeys(map);
			for (int i = 0; i < tclistnum(list); i++) {
				char *itemname = tclistval2(list, i);
				fprintf(stdout, "%s\n", itemname);
			}
			fprintf(stdout, "<<<\n");
		} else {
			fprintf(stdout, "no root object\n");
		}
	}
	tcmpooldel(mpool);
	return 0;
}
