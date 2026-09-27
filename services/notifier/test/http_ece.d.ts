declare module "http_ece" {
  const ece: {
    decrypt(
      buffer: Buffer,
      params: { version: string; privateKey: unknown; authSecret: Buffer },
    ): Buffer;
  };
  export default ece;
}
