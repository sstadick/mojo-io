"""Buffered files with binary-safe reads and writes."""

# Derived from ExtraMojo's buffered I/O (MIT, Seth Stadick, 2021).

from std.memory import unsafe_memcpy
from mojo_bstr.search import memchr

comptime BUF_SIZE = 128 * 1024


# Stable closes by mutation; nightly consumes the handle. Select by the
# method's ownership convention, without guessing from compiler versions.
def _close_file[close: def(mut FileHandle) raises thin -> None](var file: FileHandle) raises:
    close(file)


def _close_file[close: def(var FileHandle) raises thin -> None](var file: FileHandle) raises:
    close(file^)


struct BufferedReader(Movable):
    """Own a file handle and reuse storage across reads.

    `read_line` returns a view borrowing this reader; consume it before reading
    again. LF and CRLF terminate lines, a bare CR does not. A final terminator
    adds no extra line. NUL and malformed UTF-8 are ordinary bytes.
    """

    var _file: Optional[FileHandle]
    var _buffer: List[UInt8]
    var _line: List[UInt8]
    var _offset: Int
    var _length: Int
    var _eof: Bool

    def __init__(out self, var file: FileHandle, buffer_capacity: Int = BUF_SIZE) raises:
        """Take ownership of a file; capacity must be positive."""
        if buffer_capacity <= 0:
            raise Error("buffer_capacity must be positive")
        self._file = Optional(file^)
        self._buffer = List[UInt8](length=buffer_capacity, fill=0)
        self._line = List[UInt8]()
        self._offset = 0
        self._length = 0
        self._eof = False

    def _fill(mut self) raises -> Int:
        self._offset = 0
        self._length = self._file.value().read(Span(self._buffer))
        self._eof = self._length == 0
        return self._length

    def close(mut self) raises:
        """Close the underlying file; closing again is harmless."""
        self._offset = 0
        self._length = 0
        self._eof = True
        if self._file:
            _close_file[FileHandle.close](self._file.take())

    def read_bytes(mut self, mut buffer: List[UInt8]) raises -> Int:
        """Fill at most len(buffer) bytes, returning the number read.

        An empty destination consumes nothing. Only a zero-byte underlying
        read means EOF; short reads are handled without seeking.
        """
        var count = 0
        while count < len(buffer):
            if self._offset == self._length:
                if self._eof or self._fill() == 0:
                    break
            var take = min(len(buffer) - count, self._length - self._offset)
            unsafe_memcpy(
                dest=buffer.unsafe_ptr().unsafe_offset(count),
                src=self._buffer.unsafe_ptr().unsafe_offset(self._offset),
                count=take,
            )
            self._offset += take
            count += take
        return count

    def read_until(mut self, mut buffer: List[UInt8], char: UInt8 = 10) raises -> Int:
        """Append bytes before a delimiter, consuming but not appending it.

        Return bytes consumed, including the delimiter. Zero means EOF, not an
        empty record. Existing destination bytes are not counted or cleared.
        """
        var consumed = 0
        while True:
            if self._offset == self._length:
                if self._eof or self._fill() == 0:
                    return consumed
            var available = Span(self._buffer)[self._offset : self._length]
            var found = memchr(char, available)
            var take = found if found >= 0 else len(available)
            buffer.extend(available[:take])
            self._offset += take
            consumed += take
            if found >= 0:
                self._offset += 1
                return consumed + 1

    @always_inline
    def read_line(mut self) raises -> Optional[Span[UInt8, ImmOrigin(origin_of(self))]]:
        """Borrow the next line without LF/CRLF, or None at EOF.

        Consume the view before the next read, close, move, or destruction.
        A final unterminated CR remains data.
        """
        # Both allocations are owned by self. Tie views to the whole reader,
        # not one field. Mojo 1.2 does not enforce all mutation exclusions;
        # callers must consume a view before reading again.
        comptime View = Span[UInt8, ImmOrigin(origin_of(self))]
        # Avoid search setup and spill-buffer bookkeeping for empty records.
        if self._offset < self._length and self._buffer[self._offset] == 10:
            self._offset += 1
            return View(
                unsafe_ptr=self._buffer.unsafe_ptr()
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[View.origin](),
                length=0,
            )
        self._line.clear()
        while True:
            if self._offset == self._length:
                if self._eof or self._fill() == 0:
                    if len(self._line):
                        return View(
                            unsafe_ptr=self._line.unsafe_ptr()
                            .unsafe_mut_cast[False]()
                            .unsafe_origin_cast[View.origin](),
                            length=len(self._line),
                        )
                    return None
            var start = self._offset
            var found = memchr(10, Span(self._buffer)[start : self._length])
            if found >= 0:
                var end = start + found
                self._offset = end + 1
                if len(self._line) == 0:
                    if end > start and self._buffer[end - 1] == 13:
                        end -= 1
                    return View(
                        unsafe_ptr=self._buffer.unsafe_ptr()
                        .unsafe_offset(start)
                        .unsafe_mut_cast[False]()
                        .unsafe_origin_cast[View.origin](),
                        length=end - start,
                    )
                self._line.extend(Span(self._buffer)[start:end])
                var line_end = len(self._line)
                if line_end and self._line[line_end - 1] == 13:
                    line_end -= 1
                return View(
                    unsafe_ptr=self._line.unsafe_ptr()
                    .unsafe_mut_cast[False]()
                    .unsafe_origin_cast[View.origin](),
                    length=line_end,
                )
            self._line.extend(Span(self._buffer)[start : self._length])
            self._offset = self._length


struct BufferedWriter(Movable):
    """Buffer binary writes to an owned file; call close to observe errors.

    Writes never reinterpret bytes as UTF-8. A failed write poisons the writer
    so a retry or destructor cannot duplicate a partially written buffer.
    Destruction attempts to flush, but cannot report an error; explicit close
    is required when successful output matters.
    """

    var _file: Optional[FileHandle]
    var _buffer: List[UInt8]
    var _capacity: Int
    var _failed: Bool

    def __init__(out self, var file: FileHandle, buffer_capacity: Int = BUF_SIZE) raises:
        """Take ownership of a file; capacity must be positive."""
        if buffer_capacity <= 0:
            raise Error("buffer_capacity must be positive")
        self._file = Optional(file^)
        self._buffer = List[UInt8](capacity=buffer_capacity)
        self._capacity = buffer_capacity
        self._failed = False

    def __deinit__(deinit self):
        try:
            self.close()
        except:
            pass

    def _check(self) raises:
        if not self._file:
            raise Error("writer is closed")
        if self._failed:
            raise Error("writer has a previous write failure")

    def flush(mut self) raises:
        """Write buffered bytes completely, propagating I/O errors."""
        self._check()
        if len(self._buffer):
            self._failed = True
            self._file.value().write_all(Span(self._buffer))
            self._buffer.clear()
            self._failed = False

    def write_bytes(mut self, bytes: Span[UInt8, _]) raises:
        """Write arbitrary bytes; large unbuffered writes bypass the buffer."""
        self._check()
        var offset = 0
        while offset < len(bytes):
            if len(self._buffer) == 0 and len(bytes) - offset >= self._capacity:
                self._failed = True
                self._file.value().write_all(bytes[offset:])
                self._failed = False
                return
            var take = min(self._capacity - len(self._buffer), len(bytes) - offset)
            self._buffer.extend(bytes[offset : offset + take])
            offset += take
            if len(self._buffer) == self._capacity:
                self.flush()

    def write_string(mut self, string: StringSlice) raises:
        """Write UTF-8 text through the same binary-safe path."""
        self.write_bytes(string.as_bytes())

    def close(mut self) raises:
        """Flush and close; report errors even when destruction cannot."""
        if not self._file:
            return
        try:
            self.flush()
        except error:
            _close_file[FileHandle.close](self._file.take())
            raise error
        _close_file[FileHandle.close](self._file.take())


def read_lines(path: String, buf_size: Int = BUF_SIZE) raises -> List[List[UInt8]]:
    """Read binary lines, excluding LF/CRLF, including an unterminated tail."""
    var reader = BufferedReader(open(path, "r"), buf_size)
    var result = List[List[UInt8]]()
    while True:
        var line = reader.read_line()
        if not line:
            break
        result.append(List(line.value()))
    reader.close()
    return result^
