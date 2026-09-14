/* Step atomic-builtin-small-widths-1: gcc's atomic builtins on 1- and 2-byte
 * objects, and the bitwise fetch forms.
 *
 * A one-byte spinlock taken with __atomic_exchange_n (the shape facil.io's
 * fio_lock_i uses, which stopped iodine 0.7.59 from building) guards a plain
 * counter shared by four threads; alongside it the threads bump byte and
 * halfword counters with fetch_add / sub_fetch, and or/and their own bit into
 * a shared flag byte. Every total is known in advance, so a torn or lost
 * update would print a different number. A single-threaded tail shows the
 * results extended the way the object's type says: an unsigned char holding
 * 0xF0 reads as 240, a signed char holding the same bits as -16, and a
 * compare-exchange on a signed char matches an expected -1 against 0xFF. */
#include <pthread.h>
#include <stdio.h>

#define THREADS 4
#define ROUNDS 5000

static unsigned char lock;
static long guarded;
static unsigned char byte_counter;
static short half_counter;
static unsigned char flags;

static void *work(void *arg) {
  unsigned char bit = (unsigned char)(1u << (long)arg);
  for (int i = 0; i < ROUNDS; i++) {
    while (__atomic_exchange_n(&lock, 1, __ATOMIC_ACQUIRE))
      ;
    guarded++;
    __atomic_store_n(&lock, 0, __ATOMIC_RELEASE);

    __atomic_fetch_add(&byte_counter, 3, __ATOMIC_SEQ_CST);
    __atomic_sub_fetch(&half_counter, 7, __ATOMIC_SEQ_CST);
    __atomic_fetch_or(&flags, bit, __ATOMIC_SEQ_CST);
    __atomic_and_fetch(&flags, (unsigned char)~bit, __ATOMIC_SEQ_CST);
  }
  return 0;
}

int main(void) {
  pthread_t threads[THREADS];
  for (long t = 0; t < THREADS; t++)
    pthread_create(&threads[t], 0, work, (void *)t);
  for (int t = 0; t < THREADS; t++)
    pthread_join(threads[t], 0);
  printf("guarded=%ld byte=%u half=%d flags=%u lock=%u\n",
         guarded, byte_counter, half_counter, flags, lock);

  unsigned char u = 0x0F;
  signed char s = 0x0F;
  unsigned char old_u = __atomic_fetch_xor(&u, 0xFF, __ATOMIC_SEQ_CST);
  signed char old_s = __sync_fetch_and_xor(&s, (signed char)0xFF);
  printf("xor: %u->%u %d->%d\n", old_u, u, old_s, s);

  signed char expected = -1;
  signed char minus_one = -1;
  int won = __atomic_compare_exchange_n(&minus_one, &expected, 100, 0,
                                        __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  printf("cas: %d %d\n", won, minus_one);

  unsigned short wide = 65535;
  unsigned short after = __atomic_add_fetch(&wide, 2, __ATOMIC_SEQ_CST);
  printf("wrap: %u %u\n", after, wide);
  return 0;
}
