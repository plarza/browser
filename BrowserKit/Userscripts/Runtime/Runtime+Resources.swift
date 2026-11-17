extension UserscriptRuntime {
    /// GM_getResourceText and GM_getResourceURL, from the @resource files
    /// fetched when the script was installed: nothing is fetched here.
    static let resources = #"""
      const resources = Object.create(null);
      for (const [n, mime, data] of C.resources) resources[n] = {mime, data};
      const getResourceText = n => { const r = resources[n]; return r ? new TextDecoder_().decode(bytes(r.data)) : undefined; };
      const blobs = Object.create(null);
      const getResourceURL = (n, blob) => {
        const r = resources[n];
        if (!r) return undefined;
        if (blob === false) return 'data:' + r.mime + ';base64,' + r.data;
        return blobs[n] || (blobs[n] = URL_.createObjectURL(new Blob_([bytes(r.data)], {type: r.mime})));
      };
    """#
}
