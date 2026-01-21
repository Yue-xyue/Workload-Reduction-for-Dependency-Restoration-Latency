// bin/boottime_now.c
#define _GNU_SOURCE
#include <stdio.h>
#include <time.h>
int main(void){
  struct timespec ts;
  if (clock_gettime(CLOCK_BOOTTIME, &ts) != 0) return 1;
  long long ns = (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
  printf("%lld\n", ns);
  return 0;
}


