// json2dir: create the directory tree a JSON document describes, in the current directory.
// Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
//
// Plain Objective-C on the bare GNU Objective-C runtime (libobjc): our own root class, no Foundation.
// The file system is driven through libc POSIX calls; the JSON parser is written by hand.

#include <objc/runtime.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

__attribute__((noreturn)) static void fail(const char *fmt, const char *arg) {
  fprintf(stderr, "json2dir: ");
  fprintf(stderr, fmt, arg);
  fprintf(stderr, "\n");
  exit(1);
}

// ---- A tiny root class ------------------------------------------------------------------------

__attribute__((objc_root_class))
@interface J2DObject {
  Class isa;
}
+ (id)alloc;
+ (id)new;
- (id)init;
@end

@implementation J2DObject
+ (id)alloc { return class_createInstance(self, 0); }
+ (id)new { return [[self alloc] init]; }
- (id)init { return self; }
@end

// ---- Byte strings -----------------------------------------------------------------------------

@interface J2DBytes : J2DObject {
@public
  char *data;
  size_t length, capacity;
}
- (void)appendByte:(unsigned char)b;
- (void)appendCodePoint:(unsigned long)cp;
- (BOOL)isEqualToCString:(const char *)s;
- (BOOL)containsNul;
- (int)compare:(J2DBytes *)other;
@end

@implementation J2DBytes
- (id)init {
  capacity = 16;
  data = malloc(capacity);
  length = 0;
  data[0] = 0;
  return self;
}
- (void)appendByte:(unsigned char)b {
  if (length + 2 > capacity) {
    capacity *= 2;
    data = realloc(data, capacity);
  }
  data[length++] = (char)b;
  data[length] = 0;  // always NUL-terminated for use as a C path
}
- (void)appendCodePoint:(unsigned long)cp {
  if (cp < 0x80) {
    [self appendByte:cp];
  } else if (cp < 0x800) {
    [self appendByte:0xC0 | (cp >> 6)];
    [self appendByte:0x80 | (cp & 0x3F)];
  } else if (cp < 0x10000) {
    [self appendByte:0xE0 | (cp >> 12)];
    [self appendByte:0x80 | ((cp >> 6) & 0x3F)];
    [self appendByte:0x80 | (cp & 0x3F)];
  } else {
    [self appendByte:0xF0 | (cp >> 18)];
    [self appendByte:0x80 | ((cp >> 12) & 0x3F)];
    [self appendByte:0x80 | ((cp >> 6) & 0x3F)];
    [self appendByte:0x80 | (cp & 0x3F)];
  }
}
- (BOOL)isEqualToCString:(const char *)s {
  return strlen(s) == length && memcmp(data, s, length) == 0;
}
- (BOOL)containsNul { return memchr(data, 0, length) != NULL; }
- (int)compare:(J2DBytes *)other {
  size_t n = length < other->length ? length : other->length;
  int c = memcmp(data, other->data, n);
  if (c != 0) return c;
  return length < other->length ? -1 : length > other->length ? 1 : 0;
}
@end

// ---- The validated tree -----------------------------------------------------------------------

@interface J2DNode : J2DObject
- (void)applyAt:(const char *)path;
@end

@interface J2DFile : J2DNode {
@public
  J2DBytes *content;
  BOOL executable;
}
@end

@interface J2DLink : J2DNode {
@public
  J2DBytes *target;
}
@end

@interface J2DDir : J2DNode {
@public
  J2DBytes **names;
  J2DNode **children;
  size_t count, capacity;
}
- (void)setChild:(J2DNode *)child forName:(J2DBytes *)name;
- (void)sortByName;
@end

// lstat that reports "nothing there" as 0; any other error is fatal.
static int lookup(const char *path, struct stat *st) {
  if (lstat(path, st) == 0) return 1;
  if (errno == ENOENT) return 0;
  fail("%s: cannot lstat", path);
  return 0;
}

// §5.2, §5.3: an existing non-directory is removed (a symlink itself, never its target);
// §5.4: a directory in the way of a non-object is an error.
static void clearPath(const char *path) {
  struct stat st;
  if (!lookup(path, &st)) return;
  if (S_ISDIR(st.st_mode)) fail("%s: a directory is in the way", path);
  if (unlink(path) != 0) fail("%s: cannot remove", path);
}

@implementation J2DNode
- (void)applyAt:(const char *)path { (void)path; }
@end

@implementation J2DFile
- (void)applyAt:(const char *)path {
  clearPath(path);
  // O_EXCL | O_NOFOLLOW: never write through an entry that appeared after clearPath().
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0666);
  if (fd < 0) fail("%s: cannot create file", path);
  size_t done = 0;
  while (done < content->length) {
    ssize_t n = write(fd, content->data + done, content->length - done);
    if (n < 0) {
      if (errno == EINTR) continue;
      fail("%s: cannot write", path);
    }
    done += (size_t)n;
  }
  if (executable) {
    struct stat st;
    if (fstat(fd, &st) != 0 || fchmod(fd, (st.st_mode & 07777) | 0111) != 0) fail("%s: cannot chmod", path);
  }
  if (close(fd) != 0) fail("%s: cannot close", path);
}
@end

@implementation J2DLink
- (void)applyAt:(const char *)path {
  clearPath(path);
  if (symlink(target->data, path) != 0) fail("%s: cannot create symlink", path);
}
@end

@implementation J2DDir
- (id)init {
  capacity = 8;
  count = 0;
  names = malloc(capacity * sizeof *names);
  children = malloc(capacity * sizeof *children);
  return self;
}
- (void)setChild:(J2DNode *)child forName:(J2DBytes *)name {
  // §4.2: duplicate names - the last occurrence wins.
  for (size_t i = 0; i < count; i++)
    if ([names[i] compare:name] == 0) {
      children[i] = child;
      return;
    }
  if (count == capacity) {
    capacity *= 2;
    names = realloc(names, capacity * sizeof *names);
    children = realloc(children, capacity * sizeof *children);
  }
  names[count] = name;
  children[count] = child;
  count++;
}
- (void)sortByName {
  // Insertion sort by UTF-8 bytes, like the reference implementation.
  for (size_t i = 1; i < count; i++) {
    J2DBytes *n = names[i];
    J2DNode *c = children[i];
    size_t j = i;
    while (j > 0 && [names[j - 1] compare:n] > 0) {
      names[j] = names[j - 1];
      children[j] = children[j - 1];
      j--;
    }
    names[j] = n;
    children[j] = c;
  }
}
- (void)applyAt:(const char *)path {
  if (path != NULL) {  // NULL = the current directory (the root)
    struct stat st;
    int exists = lookup(path, &st);
    if (!exists || !S_ISDIR(st.st_mode)) {
      if (exists && unlink(path) != 0) fail("%s: cannot remove", path);
      if (mkdir(path, 0777) != 0) fail("%s: cannot create directory", path);
    }
  }
  [self sortByName];
  for (size_t i = 0; i < count; i++) {
    J2DBytes *child = [J2DBytes new];
    if (path != NULL) {
      for (const char *p = path; *p; p++) [child appendByte:*p];
      [child appendByte:'/'];
    }
    for (size_t k = 0; k < names[i]->length; k++) [child appendByte:names[i]->data[k]];
    [children[i] applyAt:child->data];
  }
}
@end

// ---- The parser: strict UTF-8 (§3), strict JSON, validation (§4, §6) --------------------------

@interface J2DParser : J2DObject {
  const unsigned char *buf;
  size_t len, pos;
}
- (id)initWithBytes:(const unsigned char *)bytes length:(size_t)length;
- (J2DDir *)parseDocument;
@end

@implementation J2DParser
- (id)initWithBytes:(const unsigned char *)bytes length:(size_t)length {
  buf = bytes;
  len = length;
  pos = 0;
  return self;
}

- (void)checkUtf8 {
  size_t i = 0;
  while (i < len) {
    unsigned char c = buf[i];
    size_t n;
    unsigned long cp, min;
    if (c < 0x80) { i++; continue; }
    else if ((c & 0xE0) == 0xC0) { n = 1; cp = c & 0x1F; min = 0x80; }
    else if ((c & 0xF0) == 0xE0) { n = 2; cp = c & 0x0F; min = 0x800; }
    else if ((c & 0xF8) == 0xF0) { n = 3; cp = c & 0x07; min = 0x10000; }
    else fail("%s", "input is not valid UTF-8");
    for (size_t k = 1; k <= n; k++) {
      if (i + k >= len || (buf[i + k] & 0xC0) != 0x80) fail("%s", "input is not valid UTF-8");
      cp = (cp << 6) | (buf[i + k] & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) fail("%s", "input is not valid UTF-8");
    i += n + 1;
  }
}

- (void)skipSpace {
  while (pos < len && (buf[pos] == ' ' || buf[pos] == '\t' || buf[pos] == '\n' || buf[pos] == '\r')) pos++;
}

- (void)expect:(unsigned char)c {
  [self skipSpace];
  if (pos >= len || buf[pos] != c) fail("input is not valid JSON: expected '%s'", (char[]){(char)c, 0});
  pos++;
}

- (unsigned long)hex4 {
  if (pos + 4 > len) fail("%s", "input is not valid JSON: bad \\u escape");
  unsigned long v = 0;
  for (int k = 0; k < 4; k++) {
    unsigned char c = buf[pos++];
    v <<= 4;
    if (c >= '0' && c <= '9') v |= c - '0';
    else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
    else fail("%s", "input is not valid JSON: bad \\u escape");
  }
  return v;
}

- (J2DBytes *)parseString {
  [self expect:'"'];
  J2DBytes *s = [J2DBytes new];
  for (;;) {
    if (pos >= len) fail("%s", "input is not valid JSON: unterminated string");
    unsigned char c = buf[pos++];
    if (c == '"') return s;
    if (c < 0x20) fail("%s", "input is not valid JSON: control character in string");
    if (c != '\\') { [s appendByte:c]; continue; }
    if (pos >= len) fail("%s", "input is not valid JSON: unterminated string");
    c = buf[pos++];
    switch (c) {
      case '"': [s appendByte:'"']; break;
      case '\\': [s appendByte:'\\']; break;
      case '/': [s appendByte:'/']; break;
      case 'b': [s appendByte:'\b']; break;
      case 'f': [s appendByte:'\f']; break;
      case 'n': [s appendByte:'\n']; break;
      case 'r': [s appendByte:'\r']; break;
      case 't': [s appendByte:'\t']; break;
      case 'u': {
        unsigned long cp = [self hex4];
        if (cp >= 0xDC00 && cp <= 0xDFFF) fail("%s", "string contains an unpaired surrogate");
        if (cp >= 0xD800 && cp <= 0xDBFF) {
          // §3.5: a high surrogate must be followed by an escaped low surrogate.
          if (pos + 2 > len || buf[pos] != '\\' || buf[pos + 1] != 'u')
            fail("%s", "string contains an unpaired surrogate");
          pos += 2;
          unsigned long lo = [self hex4];
          if (lo < 0xDC00 || lo > 0xDFFF) fail("%s", "string contains an unpaired surrogate");
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
        }
        [s appendCodePoint:cp];
        break;
      }
      default: fail("%s", "input is not valid JSON: bad escape");
    }
  }
}

// §4.3: an array must be ["link", target] or ["script", content].
- (J2DNode *)parseArray {
  [self expect:'['];
  [self skipSpace];
  if (pos >= len || buf[pos] != '"') fail("%s", "an array must be [\"link\", target] or [\"script\", content]");
  J2DBytes *kind = [self parseString];
  [self skipSpace];
  if (pos >= len || buf[pos] != ',') fail("%s", "an array must be [\"link\", target] or [\"script\", content]");
  pos++;
  [self skipSpace];
  if (pos >= len || buf[pos] != '"') fail("%s", "an array must be [\"link\", target] or [\"script\", content]");
  J2DBytes *arg = [self parseString];
  [self skipSpace];
  if (pos >= len || buf[pos] != ']') fail("%s", "an array must be [\"link\", target] or [\"script\", content]");
  pos++;
  if ([kind isEqualToCString:"link"]) {
    // §10: a link target with NUL cannot be created.
    if ([arg containsNul]) fail("%s", "a link target cannot contain NUL");
    J2DLink *l = [J2DLink new];
    l->target = arg;
    return l;
  }
  if ([kind isEqualToCString:"script"]) {
    J2DFile *f = [J2DFile new];
    f->content = arg;
    f->executable = YES;
    return f;
  }
  fail("unknown array kind \"%s\"", kind->data);
  return nil;
}

- (J2DDir *)parseObject {
  [self expect:'{'];
  J2DDir *dir = [J2DDir new];
  [self skipSpace];
  if (pos < len && buf[pos] == '}') { pos++; return dir; }
  for (;;) {
    [self skipSpace];
    J2DBytes *name = [self parseString];
    // §4.2.1: names are used exactly.
    if (name->length == 0 || [name isEqualToCString:"."] || [name isEqualToCString:".."] ||
        memchr(name->data, '/', name->length) || [name containsNul])
      fail("invalid name \"%s\"", name->data);
    [self expect:':'];
    [dir setChild:[self parseValue] forName:name];
    [self skipSpace];
    if (pos < len && buf[pos] == ',') { pos++; continue; }
    [self expect:'}'];
    return dir;
  }
}

- (J2DNode *)parseValue {
  [self skipSpace];
  if (pos >= len) fail("%s", "input is not valid JSON: unexpected end");
  unsigned char c = buf[pos];
  if (c == '{') return [self parseObject];
  if (c == '[') return [self parseArray];
  if (c == '"') {
    J2DFile *f = [J2DFile new];
    f->content = [self parseString];
    f->executable = NO;
    return f;
  }
  fail("%s", "numbers, true, false and null are not allowed (or the input is not valid JSON)");
  return nil;
}

- (J2DDir *)parseDocument {
  [self checkUtf8];
  if (len >= 3 && buf[0] == 0xEF && buf[1] == 0xBB && buf[2] == 0xBF) pos = 3;  // §3: ignore a BOM
  [self skipSpace];
  if (pos >= len || buf[pos] != '{') fail("%s", "the root of the document must be an object");
  J2DDir *root = [self parseObject];
  [self skipSpace];
  if (pos != len) fail("%s", "input is not valid JSON: trailing data");
  return root;
}
@end

// ---- main -------------------------------------------------------------------------------------

int main(int argc, char **argv) {
  (void)argv;
  if (argc > 1) {
    fprintf(stderr, "usage: json2dir < document.json\n");
    return 2;
  }
  size_t cap = 65536, len = 0;
  unsigned char *bytes = malloc(cap);
  for (;;) {
    if (len == cap) bytes = realloc(bytes, cap *= 2);
    ssize_t n = read(0, bytes + len, cap - len);
    if (n < 0) {
      if (errno == EINTR) continue;
      fail("%s", "cannot read stdin");
    }
    if (n == 0) break;
    len += (size_t)n;
  }
  // The whole document is parsed and validated before anything is written.
  J2DDir *root = [[[J2DParser alloc] initWithBytes:bytes length:len] parseDocument];
  [root applyAt:NULL];
  return 0;
}
