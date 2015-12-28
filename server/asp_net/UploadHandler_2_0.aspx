<%@ Page ContentType="application/json" %>

<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.IO" %>

<script language="C#" runat="server">    

    //  Sergey Dobychin 
    //  dobychin@gmail.com
    //  May, 2014

    // don't forget about IIS site settings 
    //<system.web>
    //    <httpRuntime executionTimeout="9999999" maxRequestLength="2097151" />
    //</system.web>
    //<system.webServer>
    //    <security>
    //        <requestFiltering>
    //            <requestLimits maxAllowedContentLength="2147483648" />
    //        </requestFiltering>
    //    </security>
    //</system.webServer>    

    private static readonly FilesDisposition FILES_DISPOSITION = FilesDisposition.ServerRoot;
    private static readonly string FILES_PATH = @"/files";

    private static readonly string FILE_QUERY_VAR = "file";
    private static readonly string FILE_GET_CONTENT_TYPE = "application/octet-stream";

    private static readonly int ATTEMPTS_TO_WRITE = 3;
    private static readonly int ATTEMPT_WAIT = 100; //msec

    private static readonly int BUFFER_SIZE = 4 * 1024 * 1024;
    
    private enum FilesDisposition
    {
        ServerRoot,
        HandlerRoot,
        Absolute
    }
        
    private static class HttpMethods
    {
        public static readonly string GET = "GET";
        public static readonly string POST = "POST";
        public static readonly string DELETE = "DELETE";
    }
    
    protected string SerializeDictionary(Dictionary<string, object> dictionary)
    {
        StringBuilder Result = new StringBuilder();
         
        foreach (string Key in dictionary.Keys)
        {
            object Value = dictionary[Key];
            
            string FormatStr = String.Empty;
            
            switch (Value.GetType().Name)
            {
                case "String": //all will be packed
                case "string":
                    FormatStr = ",\"{0}\":\"{1}\"";
                    break;
                case "Boolean":
                case "bool":
                    FormatStr = ",\"{0}\":{1}";
                    Value = Value.ToString().ToLower();
                    break;
                case "Int64":
                case "Int32":
                case "int":
                    FormatStr = ",\"{0}\":{1}";
                    break;
                case "List`1":
                    FormatStr = ",\"{0}\":[{1}]";
                    
                    Value = String.Empty;
                    
                    foreach (Dictionary<string, object> SubDictionary in (dictionary[Key] as List<Dictionary<string, object>>))
                    {
                        Value += "," + SerializeDictionary(SubDictionary);
                    }

                    if (Value.ToString().Length > 0)
                    {
                        Value = Value.ToString().Substring(1);
                    }
                    break;
                case "Dictionary`2":
                    FormatStr = ",\"{0}\":[{1}]";
                    Value = SerializeDictionary(Value as Dictionary<string, object>);
                    
                    break;
            }
                          
            Result.Append(String.Format(FormatStr, Key, Value));
        }

        return "{" + (Result.Length > 0 ? Result.ToString().Substring(1) : String.Empty) + "}";
    }

    private string CreateFileUrl(string fileName, FilesDisposition filesDisposition)
    {
        switch (filesDisposition)
        {
            case FilesDisposition.ServerRoot:
                // 1. files directory lies in root directory catalog WRONG
                return String.Format("{0}{1}/{2}", Request.Url.GetLeftPart(UriPartial.Authority),
                    FILES_PATH, Path.GetFileName(fileName));

            case FilesDisposition.HandlerRoot:
                // 2. files directory lays in current page catalog WRONG
                return String.Format("{0}{1}{2}/{3}", Request.Url.GetLeftPart(UriPartial.Authority),
                    Path.GetDirectoryName(Request.CurrentExecutionFilePath).Replace(@"\", @"/"), FILES_PATH, Path.GetFileName(fileName));

            case FilesDisposition.Absolute:
                // 3. files directory lays anywhere YEAH
                return String.Format("{0}?{1}={2}", Request.Url.AbsoluteUri, FILE_QUERY_VAR, HttpUtility.UrlEncode(Path.GetFileName(fileName)));
            default:
                return String.Empty;
        }
    }

    private Dictionary<string, object> CreateFileDictionary(string fileName, long size, string error)
    {
        Dictionary<string, object> Result = new Dictionary<string, object>();

        Result.Add("name", Path.GetFileName(fileName));
        Result.Add("size", size.ToString());
        Result.Add("type", String.Empty);
        Result.Add("url", CreateFileUrl(fileName, FILES_DISPOSITION));
        Result.Add("error", error);
        Result.Add("deleteUrl", CreateFileUrl(fileName, FilesDisposition.Absolute));
        Result.Add("deleteType", HttpMethods.DELETE);
        
        return Result;
    }

    private void FromStreamToStream(Stream source, Stream destination)
    {
        int BufferSize = source.Length >= BUFFER_SIZE ? BUFFER_SIZE : (int)source.Length;
        long BytesLeft = source.Length;

        byte[] Buffer = new byte[BufferSize];

        int BytesRead = 0;

        while (BytesLeft > 0)
        {
            BytesRead = source.Read(Buffer, 0, BytesLeft > BufferSize ? BufferSize : (int)BytesLeft);

            destination.Write(Buffer, 0, BytesRead);

            BytesLeft -= BytesRead;
        }
    }
    
    protected void Page_Load(object sender, EventArgs e)
    {
        string RootElementName = "files";
        object ResponseObject;
              
        string FilesPath;

        switch (FILES_DISPOSITION)
        {
            case FilesDisposition.ServerRoot:
                FilesPath = Server.MapPath(FILES_PATH);
                break;
            case FilesDisposition.HandlerRoot:
                FilesPath = Server.MapPath(Path.GetDirectoryName(Request.CurrentExecutionFilePath) + FILES_PATH);
                break;
            case FilesDisposition.Absolute:
                FilesPath = FILES_PATH;
                break;
            default:
                Response.StatusCode = 500;
                Response.StatusDescription = "Configuration error (FILES_DISPOSITION)";
                return;
        }   

        // prepare directory
        if (!Directory.Exists(FilesPath))
        {
            Directory.CreateDirectory(FilesPath);
        }


        string QueryFileName = Request[FILE_QUERY_VAR];
        string FullFileName = null;
        string FileShortName = null;

        //if (!String.IsNullOrEmpty(QueryFileName))
        if (QueryFileName != null) // param specified, but maybe in wrong format (empty). else user will download json with listed files
        {
            FileShortName = HttpUtility.UrlDecode(QueryFileName);
            FullFileName = String.Format(@"{0}\{1}", FilesPath, FileShortName);

            if (QueryFileName.Trim().Length == 0 || !File.Exists(FullFileName))
            {
                Response.StatusCode = 404;
                Response.StatusDescription = "File not found";

                Response.End();
                return;
            }
        }       
        
        if (Request.HttpMethod.ToUpper() == HttpMethods.GET)
        {           
            if (FullFileName != null)
            {
                Response.ContentType = FILE_GET_CONTENT_TYPE;                   // http://www.digiblog.de/2011/04/android-and-the-download-file-headers/ :)
                Response.AddHeader("Content-Disposition", String.Format("attachment; filename={0}{1}", Path.GetFileNameWithoutExtension(FileShortName), Path.GetExtension(FileShortName).ToUpper()));

                using (FileStream FileReader = new FileStream(FullFileName, FileMode.Open, FileAccess.Read))
                {
                    FromStreamToStream(FileReader, Response.OutputStream);
  
                    Response.OutputStream.Close();
                }

                Response.End();
                return;
            }
            else
            {
                List<Dictionary<string, object>> FileResponseList = new List<Dictionary<string, object>>();

                string[] FileNames = Directory.GetFiles(FilesPath);

                foreach (string FileName in FileNames)
                {
                    FileResponseList.Add(CreateFileDictionary(FileName, new FileInfo(FileName).Length, String.Empty));
                }

                ResponseObject = FileResponseList;
            }            
        }
        else if (Request.HttpMethod.ToUpper() == HttpMethods.POST)
        {
            List<Dictionary<string, object>> FileResponseList = new List<Dictionary<string, object>>();
            
            for (int FileIndex = 0; FileIndex < Request.Files.Count; FileIndex++)
            {
                HttpPostedFile File = Request.Files[FileIndex];

                string FileName = String.Format(@"{0}\{1}", FilesPath, Path.GetFileName(File.FileName));
                string ErrorMessage = String.Empty;
                
                for (int Attempts = 0; Attempts < ATTEMPTS_TO_WRITE; Attempts++)
                {
                    ErrorMessage = String.Empty;

                    if (System.IO.File.Exists(FileName))
                    {
                        FileName = String.Format(@"{0}\{1}_{2:yyyyMMddHHmmss.fff}{3}", FilesPath, Path.GetFileNameWithoutExtension(FileName), DateTime.Now, Path.GetExtension(FileName));
                    }
                    
                    try
                    {
                        using (Stream FileStreamWriter = new FileStream(FileName, FileMode.CreateNew, FileAccess.Write))
                        {
                            FromStreamToStream(File.InputStream, FileStreamWriter);
                        }
                    }
                    catch (Exception exception)
                    {
                        ErrorMessage = exception.Message;
                        System.Threading.Thread.Sleep(ATTEMPT_WAIT);
                        continue;
                    }
 
                    break;
                }

                FileResponseList.Add(CreateFileDictionary(FileName, File.ContentLength, ErrorMessage));
            }
            
            ResponseObject = FileResponseList;            
        }
        else if (Request.HttpMethod.ToUpper() == HttpMethods.DELETE)
        {
            RootElementName = FileShortName;
            ResponseObject = true;

            try
            {
                File.Delete(FullFileName);
            }
            catch
            {
                ResponseObject = false;
            }
        }
        else
        {
            Response.StatusCode = 405;
            Response.StatusDescription = "Method not allowed";
            Response.End();

            return;
        }
            
            
        Dictionary<string, object> ResultDictionary = new Dictionary<string, object>();
        ResultDictionary.Add(RootElementName, ResponseObject);        

        Response.Write(SerializeDictionary(ResultDictionary));
        
        Response.End();
    }
    
</script>
