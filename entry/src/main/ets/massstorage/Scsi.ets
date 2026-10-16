/*
 * SCSI command set and USB Bulk-Only Transport (BOT) framing.
 *
 * This replaces libaums' me.jahnen.libaums.core.driver.scsi package on Android.
 * Only the subset EtchDroid needs is implemented: the SCSI transparent command
 * set (SPC-3 / SBC-2) carried over BOT, as required by the USB Mass Storage
 * Class definition for interface subclass 0x06 / protocol 0x50.
 */

// --- SCSI operation codes ---------------------------------------------------

export const SCSI_TEST_UNIT_READY = 0x00;
export const SCSI_REQUEST_SENSE = 0x03;
export const SCSI_INQUIRY = 0x12;
export const SCSI_MODE_SENSE_6 = 0x1A;
export const SCSI_READ_CAPACITY_10 = 0x25;
export const SCSI_READ_10 = 0x28;
export const SCSI_WRITE_10 = 0x2A;
export const SCSI_READ_CAPACITY_16 = 0x9E;
export const SCSI_READ_12 = 0xA8;
export const SCSI_WRITE_12 = 0xAA;

// --- BOT framing constants --------------------------------------------------

/** Command Block Wrapper, "USBC" in little-endian byte order. */
export const CBW_SIGNATURE = 0x43425355;
/** Command Status Wrapper, "USBS" in little-endian byte order. */
export const CSW_SIGNATURE = 0x53425355;

export const CBW_LENGTH = 31;
export const CSW_LENGTH = 13;
export const CBWCB_LENGTH = 16;

/** bmCBWFlags: data moves from device to host. */
export const CBW_FLAGS_DATA_IN = 0x80;
/** bmCBWFlags: data moves from host to device. */
export const CBW_FLAGS_DATA_OUT = 0x00;

export const CSW_STATUS_PASSED = 0x00;
export const CSW_STATUS_FAILED = 0x01;
export const CSW_STATUS_PHASE_ERROR = 0x02;

// --- Bulk-Only class-specific control requests ------------------------------

/** GET_MAX_LUN: 0b10100001 - device-to-host, class, interface recipient. */
export const REQ_GET_MAX_LUN_TYPE = 0xA1;
export const REQ_GET_MAX_LUN = 0xFE;

/** Bulk-Only Mass Storage Reset: 0b00100001 - host-to-device, class, interface. */
export const REQ_BOT_RESET_TYPE = 0x21;
export const REQ_BOT_RESET = 0xFF;

/** CLEAR_FEATURE(ENDPOINT_HALT): 0b00000010 - host-to-device, standard, endpoint. */
export const REQ_CLEAR_FEATURE_TYPE = 0x02;
export const REQ_CLEAR_FEATURE = 0x01;
export const FEATURE_ENDPOINT_HALT = 0x00;

// --- Byte-order helpers (SCSI is big-endian throughout) ---------------------

export function writeUint16BE(target: Uint8Array, offset: number, value: number): void {
  target[offset] = (value >>> 8) & 0xFF;
  target[offset + 1] = value & 0xFF;
}

export function writeUint32BE(target: Uint8Array, offset: number, value: number): void {
  target[offset] = Math.floor(value / 0x1000000) & 0xFF;
  target[offset + 1] = (value >>> 16) & 0xFF;
  target[offset + 2] = (value >>> 8) & 0xFF;
  target[offset + 3] = value & 0xFF;
}

export function writeUint32LE(target: Uint8Array, offset: number, value: number): void {
  target[offset] = value & 0xFF;
  target[offset + 1] = (value >>> 8) & 0xFF;
  target[offset + 2] = (value >>> 16) & 0xFF;
  target[offset + 3] = Math.floor(value / 0x1000000) & 0xFF;
}

export function readUint32BE(source: Uint8Array, offset: number): number {
  return (source[offset] * 0x1000000) + (source[offset + 1] << 16) +
    (source[offset + 2] << 8) + source[offset + 3];
}

export function readUint32LE(source: Uint8Array, offset: number): number {
  return source[offset] + (source[offset + 1] << 8) + (source[offset + 2] << 16) +
    (source[offset + 3] * 0x1000000);
}

// --- Command Block Wrapper --------------------------------------------------

/** A CBW plus its optional data phase, ready to be sent over the bulk pipe. */
export class CommandBlockWrapper {
  readonly tag: number;
  readonly dataTransferLength: number;
  readonly flags: number;
  readonly lun: number;
  readonly cb: Uint8Array;

  constructor(tag: number, dataTransferLength: number, flags: number, lun: number, cb: Uint8Array) {
    this.tag = tag;
    this.dataTransferLength = dataTransferLength;
    this.flags = flags;
    this.lun = lun;
    this.cb = cb;
  }

  /** Serializes the 31-byte CBW. */
  toBytes(): Uint8Array {
    const out = new Uint8Array(CBW_LENGTH);
    writeUint32LE(out, 0, CBW_SIGNATURE);
    writeUint32LE(out, 4, this.tag);
    writeUint32LE(out, 8, this.dataTransferLength);
    out[12] = this.flags;
    out[13] = this.lun & 0x0F;
    out[14] = this.cb.length & 0x1F;
    for (let i = 0; i < this.cb.length && i < CBWCB_LENGTH; i++) {
      out[15 + i] = this.cb[i];
    }
    return out;
  }
}

/** A parsed Command Status Wrapper. */
export class CommandStatusWrapper {
  readonly signature: number;
  readonly tag: number;
  readonly dataResidue: number;
  readonly status: number;

  constructor(signature: number, tag: number, dataResidue: number, status: number) {
    this.signature = signature;
    this.tag = tag;
    this.dataResidue = dataResidue;
    this.status = status;
  }

  get isValid(): boolean {
    return this.signature === CSW_SIGNATURE;
  }

  get isPassed(): boolean {
    return this.status === CSW_STATUS_PASSED;
  }

  get isPhaseError(): boolean {
    return this.status === CSW_STATUS_PHASE_ERROR;
  }
}

export function parseCommandStatusWrapper(bytes: Uint8Array, offset: number): CommandStatusWrapper {
  return new CommandStatusWrapper(
    readUint32LE(bytes, offset),
    readUint32LE(bytes, offset + 4),
    readUint32LE(bytes, offset + 8),
    bytes[offset + 12],
  );
}

// --- Sense data -------------------------------------------------------------

/** Decoded fixed-format sense data. */
export class SenseData {
  readonly responseCode: number;
  readonly senseKey: number;
  readonly additionalSenseCode: number;
  readonly additionalSenseCodeQualifier: number;

  constructor(responseCode: number, senseKey: number, asc: number, ascq: number) {
    this.responseCode = responseCode;
    this.senseKey = senseKey;
    this.additionalSenseCode = asc;
    this.additionalSenseCodeQualifier = ascq;
  }

  get isSenseValid(): boolean {
    return this.responseCode === 0x70 || this.responseCode === 0x71 || this.responseCode === 0xF0 ||
      this.responseCode === 0xF1;
  }

  /** 0x02/0x3A/0x00 - medium not present (no card in the reader). */
  get isMediumNotPresent(): boolean {
    return this.senseKey === 0x02 && this.additionalSenseCode === 0x3A;
  }

  /** 0x06/0x29 - unit attention after power-on, bus reset or media change. */
  get isUnitAttention(): boolean {
    return this.senseKey === 0x06;
  }

  /** 0x07/0x27 - the medium is write protected. */
  get isWriteProtected(): boolean {
    return this.senseKey === 0x07 && this.additionalSenseCode === 0x27;
  }

  get hasSenseKey(): boolean {
    return (this.senseKey & 0x0F) !== 0;
  }

  toString(): string {
    const key = `0x${this.senseKey.toString(16)}`;
    const asc = `0x${this.additionalSenseCode.toString(16)}`;
    const ascq = `0x${this.additionalSenseCodeQualifier.toString(16)}`;
    return `key=${key} asc=${asc} ascq=${ascq}`;
  }
}

export function parseSenseData(bytes: Uint8Array, offset: number): SenseData {
  const responseCode = bytes[offset] & 0x7F;
  const senseKey = bytes[offset + 2] & 0x0F;
  const asc = bytes[offset + 12];
  const ascq = bytes[offset + 13];
  return new SenseData(responseCode, senseKey, asc, ascq);
}

// --- CDB builders -----------------------------------------------------------

export function cdbTestUnitReady(): Uint8Array {
  const cb = new Uint8Array(6);
  cb[0] = SCSI_TEST_UNIT_READY;
  return cb;
}

export function cdbRequestSense(allocationLength: number): Uint8Array {
  const cb = new Uint8Array(6);
  cb[0] = SCSI_REQUEST_SENSE;
  cb[4] = allocationLength & 0xFF;
  return cb;
}

export function cdbInquiry(allocationLength: number): Uint8Array {
  const cb = new Uint8Array(6);
  cb[0] = SCSI_INQUIRY;
  cb[4] = allocationLength & 0xFF;
  return cb;
}

export function cdbReadCapacity10(): Uint8Array {
  const cb = new Uint8Array(10);
  cb[0] = SCSI_READ_CAPACITY_10;
  return cb;
}

export function cdbReadCapacity16(): Uint8Array {
  const cb = new Uint8Array(16);
  cb[0] = SCSI_READ_CAPACITY_16;
  cb[1] = 0x10; // service action: READ CAPACITY(16)
  writeUint32BE(cb, 10, 32);
  return cb;
}

const MAX_BLOCKS_PER_CDB = 0xFFFF;

/**
 * Builds a READ(10) or WRITE(10) CDB. The 10-byte variants carry a 16-bit transfer
 * length, so larger requests are rejected here and split by the caller.
 */
function cdbReadWrite10(opcode: number, blockAddress: number, numberOfBlocks: number): Uint8Array {
  const cb = new Uint8Array(10);
  cb[0] = opcode;
  writeUint32BE(cb, 2, blockAddress);
  writeUint16BE(cb, 7, numberOfBlocks);
  return cb;
}

function cdbReadWrite12(opcode: number, blockAddress: number, numberOfBlocks: number): Uint8Array {
  const cb = new Uint8Array(12);
  cb[0] = opcode;
  writeUint32BE(cb, 2, blockAddress);
  writeUint32BE(cb, 6, numberOfBlocks);
  return cb;
}

/**
 * Picks the narrowest READ/WRITE CDB that can express the request, mirroring the
 * adaptive command sizing libaums performs.
 */
export function cdbReadWrite(isWrite: boolean, blockAddress: number, numberOfBlocks: number): Uint8Array {
  if (numberOfBlocks > MAX_BLOCKS_PER_CDB) {
    return cdbReadWrite12(isWrite ? SCSI_WRITE_12 : SCSI_READ_12, blockAddress, numberOfBlocks);
  }
  return cdbReadWrite10(isWrite ? SCSI_WRITE_10 : SCSI_READ_10, blockAddress, numberOfBlocks);
}

/** Largest number of blocks a single CDB built by cdbReadWrite may address. */
export { MAX_BLOCKS_PER_CDB };
