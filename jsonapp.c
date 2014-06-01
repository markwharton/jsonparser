/* gcc -I/usr/local/include jsonapp.c -o jsonapp -L/usr/local/lib -ljsonparser */

#include <jsonparser.h>

char *jsonTypes[] = { NULL, "string", "number", "{}", "[]", "true", "false", "null" };

bool jsonAddElement(void *userData, void *item, JSONParserValue *value)
{
  char *elementValue = value->string; /* string and number */
  elementValue = elementValue ? elementValue : jsonTypes[value->type];
  return fprintf(stdout, "element: %s\n", elementValue) > 0;
}

bool jsonSetMember(void *userData, void *item, char *name, JSONParserValue *value)
{
  char *memberValue = value->string; /* string and number */
  memberValue = memberValue ? memberValue : jsonTypes[value->type];
  return fprintf(stdout, "member: %s = %s\n", name, memberValue) > 0;
}

int main(int argc, char **argv)
{
  JSONParser parser = createJSONParser(NULL);
  if (parser) {
    jsonParserConfigureCallbacks(parser, jsonAddElement, NULL, jsonSetMember);
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
