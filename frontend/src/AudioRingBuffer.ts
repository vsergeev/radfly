export class AudioRingBuffer {
  buffer: Float32Array;
  read_index: Uint32Array;
  write_index: Uint32Array;

  constructor(buffer_sab: SharedArrayBuffer, read_index_sab: SharedArrayBuffer, write_index_sab: SharedArrayBuffer) {
    this.buffer = new Float32Array(buffer_sab);
    this.read_index = new Uint32Array(read_index_sab);
    this.write_index = new Uint32Array(write_index_sab);
  }

  private _writeAvailable(read_index: number, write_index: number): number {
    if (read_index <= write_index) {
      return this.buffer.length - write_index + read_index - 1;
    } else {
      return read_index - write_index - 1;
    }
  }

  private _readAvailable(read_index: number, write_index: number): number {
    if (read_index <= write_index) {
      return write_index - read_index;
    } else {
      return this.buffer.length - read_index + write_index;
    }
  }

  public writeAvailable(): number {
    return this._writeAvailable(Atomics.load(this.read_index, 0), Atomics.load(this.write_index, 0));
  }

  public readAvailable(): number {
    return this._readAvailable(Atomics.load(this.read_index, 0), Atomics.load(this.write_index, 0));
  }

  write(data: Float32Array): boolean {
    const read_index = Atomics.load(this.read_index, 0);
    const write_index = Atomics.load(this.write_index, 0);

    if (this._writeAvailable(read_index, write_index) < data.length) {
      return false;
    }

    if (write_index + data.length < this.buffer.length) {
      this.buffer.subarray(write_index, write_index + data.length).set(data);
      Atomics.store(this.write_index, 0, write_index + data.length);
    } else {
      const count = this.buffer.length - write_index;
      this.buffer.subarray(write_index).set(data.subarray(0, count));
      this.buffer.subarray(0, data.length - count).set(data.subarray(count));
      Atomics.store(this.write_index, 0, data.length - count);
    }

    return true;
  }

  read(data: Float32Array): boolean {
    const read_index = Atomics.load(this.read_index, 0);
    const write_index = Atomics.load(this.write_index, 0);

    if (this._readAvailable(read_index, write_index) < data.length) {
      return false;
    }

    if (read_index + data.length < this.buffer.length) {
      data.set(this.buffer.subarray(read_index, read_index + data.length));
      Atomics.store(this.read_index, 0, read_index + data.length);
    } else {
      const count = this.buffer.length - read_index;
      data.set(this.buffer.subarray(read_index));
      data.subarray(count).set(this.buffer.subarray(0, data.length - count));
      Atomics.store(this.read_index, 0, data.length - count);
    }

    return true;
  }

  reset() {
    Atomics.store(this.write_index, 0, 0);
    Atomics.store(this.read_index, 0, 0);
  }
}
