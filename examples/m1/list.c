/* struct・ポインタ・NULL 終端の連結リスト。
   Step 14 で入った ヌルポインタ定数(0)と ポインタ条件式(p が真)を使う。
   スタック上にノードを 5 つ作り、値の合計 (1+2+3+4+5)*10 = 150 を返す。 */

struct Node {
    int value;
    struct Node *next;
};

int sum(struct Node *head) {
    int total = 0;
    struct Node *p;
    for (p = head; p; p = p->next) {
        total = total + p->value;
    }
    return total;
}

int main(void) {
    struct Node n1;
    struct Node n2;
    struct Node n3;
    struct Node n4;
    struct Node n5;
    n1.value = 10; n1.next = &n2;
    n2.value = 20; n2.next = &n3;
    n3.value = 30; n3.next = &n4;
    n4.value = 40; n4.next = &n5;
    n5.value = 50; n5.next = 0;   /* NULL 終端 */
    return sum(&n1);
}
