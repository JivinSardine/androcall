package dev.androcall.android.protocol

import java.io.ByteArrayOutputStream

/**
 * Canonical JSON serialisation (PROTOCOL.md §4.0).
 *
 * * object keys are sorted lexicographically by their UTF-8 bytes
 * * numbers are integers only
 * * no insignificant whitespace
 * * `/` is not escaped, control characters use the short escapes where they
 *   exist and `\\u00xx` (lower-case hex) otherwise
 *
 * The Swift implementation and the Python reference produce exactly the same
 * bytes for the same message; the conformance vectors pin them.
 */
object CanonicalJson {

    /** Orders object keys by their UTF-8 bytes. */
    private val UTF8_ORDER = Comparator<String> { left, right ->
        val a = left.toByteArray(Charsets.UTF_8)
        val b = right.toByteArray(Charsets.UTF_8)
        for (index in 0 until minOf(a.size, b.size)) {
            val difference = a[index].toInt() - b[index].toInt()
            if (difference != 0) return@Comparator difference
        }
        a.size - b.size
    }

    /** A JSON value restricted to the shapes the protocol carries. */
    sealed class Value {
        object Null : Value()
        data class Bool(val value: Boolean) : Value()
        data class Num(val value: Long) : Value()
        data class Str(val value: String) : Value()
        data class Arr(val items: List<Value>) : Value()
        data class Obj(val members: Map<String, Value>) : Value()
    }

    fun encode(value: Value): String = when (value) {
        is Value.Null -> "null"
        is Value.Bool -> if (value.value) "true" else "false"
        is Value.Num -> value.value.toString()
        is Value.Str -> encodeString(value.value)
        is Value.Arr -> value.items.joinToString(",", "[", "]") { encode(it) }
        is Value.Obj -> {
            val sorted = value.members.keys.sortedWith(UTF8_ORDER)
            sorted.joinToString(",", "{", "}") { key ->
                encodeString(key) + ":" + encode(value.members.getValue(key))
            }
        }
    }

    fun toBytes(value: Value): ByteArray = encode(value).toByteArray(Charsets.UTF_8)

    private fun encodeString(text: String): String {
        val out = StringBuilder()
        out.append('"')
        for (character in text) {
            when (character) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\b' -> out.append("\\b")
                '' -> out.append("\\f")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> {
                    if (character.code < 0x20) {
                        out.append(String.format("\\u%04x", character.code))
                    } else {
                        out.append(character)
                    }
                }
            }
        }
        out.append('"')
        return out.toString()
    }

    /**
     * Parse JSON text.
     *
     * Android ships `org.json`, but it is lenient in ways that would let two
     * implementations disagree, so a small strict parser is used instead.
     */
    fun parse(text: String): Value {
        val parser = Parser(text)
        val value = parser.parseValue()
        parser.skipWhitespace()
        if (!parser.atEnd()) {
            throw IllegalArgumentException("trailing data in JSON payload")
        }
        return value
    }

    fun parse(bytes: ByteArray): Value = parse(String(bytes, Charsets.UTF_8))

    private class Parser(private val text: String) {
        private var index = 0

        fun atEnd(): Boolean = index >= text.length

        fun skipWhitespace() {
            while (index < text.length && text[index].isWhitespace()) index += 1
        }

        fun parseValue(): Value {
            skipWhitespace()
            if (atEnd()) throw IllegalArgumentException("unexpected end of JSON")
            return when (text[index]) {
                '{' -> parseObject()
                '[' -> parseArray()
                '"' -> Value.Str(parseString())
                't' -> { expect("true"); Value.Bool(true) }
                'f' -> { expect("false"); Value.Bool(false) }
                'n' -> { expect("null"); Value.Null }
                else -> parseNumber()
            }
        }

        private fun expect(literal: String) {
            if (!text.startsWith(literal, index)) {
                throw IllegalArgumentException("expected '$literal' at $index")
            }
            index += literal.length
        }

        private fun parseObject(): Value {
            index += 1 // '{'
            val members = LinkedHashMap<String, Value>()
            skipWhitespace()
            if (!atEnd() && text[index] == '}') {
                index += 1
                return Value.Obj(members)
            }
            while (true) {
                skipWhitespace()
                val key = parseString()
                skipWhitespace()
                if (atEnd() || text[index] != ':') {
                    throw IllegalArgumentException("expected ':' at $index")
                }
                index += 1
                members[key] = parseValue()
                skipWhitespace()
                if (atEnd()) throw IllegalArgumentException("unterminated object")
                when (text[index]) {
                    ',' -> index += 1
                    '}' -> { index += 1; return Value.Obj(members) }
                    else -> throw IllegalArgumentException("expected ',' or '}' at $index")
                }
            }
        }

        private fun parseArray(): Value {
            index += 1 // '['
            val items = ArrayList<Value>()
            skipWhitespace()
            if (!atEnd() && text[index] == ']') {
                index += 1
                return Value.Arr(items)
            }
            while (true) {
                items.add(parseValue())
                skipWhitespace()
                if (atEnd()) throw IllegalArgumentException("unterminated array")
                when (text[index]) {
                    ',' -> index += 1
                    ']' -> { index += 1; return Value.Arr(items) }
                    else -> throw IllegalArgumentException("expected ',' or ']' at $index")
                }
            }
        }

        private fun parseString(): String {
            if (atEnd() || text[index] != '"') {
                throw IllegalArgumentException("expected a string at $index")
            }
            index += 1
            val out = StringBuilder()
            while (true) {
                if (atEnd()) throw IllegalArgumentException("unterminated string")
                val character = text[index]
                when {
                    character == '"' -> { index += 1; return out.toString() }
                    character == '\\' -> {
                        index += 1
                        if (atEnd()) throw IllegalArgumentException("unterminated escape")
                        when (val escape = text[index]) {
                            '"' -> out.append('"')
                            '\\' -> out.append('\\')
                            '/' -> out.append('/')
                            'b' -> out.append('\b')
                            'f' -> out.append('')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                if (index + 4 >= text.length) {
                                    throw IllegalArgumentException("truncated \\u escape")
                                }
                                val code = text.substring(index + 1, index + 5).toInt(16)
                                out.append(code.toChar())
                                index += 4
                            }
                            else -> throw IllegalArgumentException("unknown escape '\\$escape'")
                        }
                        index += 1
                    }
                    else -> { out.append(character); index += 1 }
                }
            }
        }

        private fun parseNumber(): Value {
            val start = index
            if (!atEnd() && text[index] == '-') index += 1
            while (!atEnd() && text[index].isDigit()) index += 1
            if (!atEnd() && (text[index] == '.' || text[index] == 'e' || text[index] == 'E')) {
                throw IllegalArgumentException("the protocol carries integers only")
            }
            if (start == index) throw IllegalArgumentException("expected a number at $index")
            val literal = text.substring(start, index)
            return Value.Num(literal.toLongOrNull()
                ?: throw IllegalArgumentException("number out of range: $literal"))
        }
    }
}

/** A helper for building canonical JSON objects. */
class JsonObjectBuilder {
    private val members = LinkedHashMap<String, CanonicalJson.Value>()

    fun put(key: String, value: CanonicalJson.Value) {
        members[key] = value
    }

    fun put(key: String, value: String) {
        members[key] = CanonicalJson.Value.Str(value)
    }

    fun put(key: String, value: Long) {
        members[key] = CanonicalJson.Value.Num(value)
    }

    fun put(key: String, value: Int) {
        members[key] = CanonicalJson.Value.Num(value.toLong())
    }

    fun put(key: String, value: Boolean) {
        members[key] = CanonicalJson.Value.Bool(value)
    }

    /** Put a value that may be absent. */
    fun putOrNull(key: String, value: String?) {
        members[key] = value?.let { CanonicalJson.Value.Str(it) } ?: CanonicalJson.Value.Null
    }

    /** Put a number that may be absent. */
    fun putOrNull(key: String, value: Long?) {
        members[key] = value?.let { CanonicalJson.Value.Num(it) } ?: CanonicalJson.Value.Null
    }

    /** Put an integer that may be absent. */
    fun putOrNull(key: String, value: Int?) {
        members[key] = value?.let { CanonicalJson.Value.Num(it.toLong()) } ?: CanonicalJson.Value.Null
    }

    /** Put a flag that may be absent. */
    fun putOrNull(key: String, value: Boolean?) {
        members[key] = value?.let { CanonicalJson.Value.Bool(it) } ?: CanonicalJson.Value.Null
    }

    fun putStrings(key: String, values: List<String>) {
        members[key] = CanonicalJson.Value.Arr(values.map { CanonicalJson.Value.Str(it) })
    }

    fun build(): CanonicalJson.Value.Obj = CanonicalJson.Value.Obj(members)
}
