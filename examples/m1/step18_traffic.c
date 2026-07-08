/* Step 18(enum・typedef)のサンプル。
   enum で信号の色(既定値 + 明示値)を定義し、typedef で状態を表す型に
   別名を付ける。switch の case ラベルに enumerator をそのまま使い、
   次の色へ遷移する。終了コード = 何ステップかけて RED に戻ったか。 */

int puts(char *s);

/* GREEN=0, YELLOW=1, RED=2。既定値が 0 から連番で振られる。 */
enum Light { GREEN, YELLOW, RED };

/* enum は int なので、その別名も int の別名になる。 */
typedef enum Light Signal;
typedef unsigned int Count;

/* 現在の色から次の色を返す(RED の次は GREEN に戻る)。 */
Signal next_color(Signal c) {
    switch (c) {
    case GREEN:
        return YELLOW;
    case YELLOW:
        return RED;
    default:
        return GREEN;
    }
}

int main(void) {
    Signal c = GREEN;
    Count steps = 0;

    /* GREEN から始めて、RED を経て再び GREEN に戻るまで遷移させる。 */
    do {
        c = next_color(c);
        steps = steps + 1;
    } while (c != GREEN);

    puts("cycled a traffic light from green back to green");
    return steps;
}
