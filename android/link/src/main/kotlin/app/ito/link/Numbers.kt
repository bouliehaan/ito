package app.ito.link

object Numbers {
    /**
     * The key two phone numbers are compared by. Digits only, and anything
     * 10 digits or longer collapses to its last 10, so "+1 (555) 123-4567",
     * "15551234567" and "5551234567" are the same person. Short codes keep all
     * their digits; alphanumeric senders ("T-Mobile") keep their text.
     */
    fun key(raw: String): String {
        val digits = raw.filter(Char::isDigit)
        return when {
            digits.length >= 10 -> digits.takeLast(10)
            digits.isNotEmpty() -> digits
            else -> raw.trim().lowercase()
        }
    }

    fun same(a: String, b: String) = key(a) == key(b)
}
