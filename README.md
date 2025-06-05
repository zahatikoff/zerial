# Zerial - My very (not) originally named serial port abstraction

The main role of this library is to make a serial port available as a simple I/O
device.

## Planned OS support

- [ ] POSIX-compatible OS's
- [ ] Windows

## Planned Features

- [ ] Blocking/non-blocking mode.
- [ ] Hardware control flow (at least RTS/CTS)
- Async I/O with poll(POSIX) or epoll/kqueue(Linux/BSD)
- Windows Async I/O
