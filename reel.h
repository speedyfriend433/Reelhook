// reel.h

#ifndef REEL_H_
#define REEL_H_

#include <stddef.h> 

struct rebinding {
  const char *name;
  void *replacement;
  void **original;
};

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_count);


#endif // REEL_H_
