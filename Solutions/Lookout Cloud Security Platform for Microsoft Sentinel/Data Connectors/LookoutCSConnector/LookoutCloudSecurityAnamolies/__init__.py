import sys
import azure.functions as func
from datetime import datetime, timedelta
import json
import base64
import hashlib
import hmac
import requests
import re
import os
import logging
from azure.storage.fileshare import ShareClient
from azure.storage.fileshare import ShareFileClient
from azure.core.exceptions import ResourceNotFoundError
from concurrent.futures import ThreadPoolExecutor, as_completed
from concurrent.futures import ProcessPoolExecutor as PE
from multiprocessing.pool import Pool
import multiprocessing as mp
import time

jwt_api_key = os.environ['LookoutClientId']
jwt_api_secret = os.environ['LookoutApiSecret']
customer_id = os.environ['WorkspaceID']
shared_key = os.environ['WorkspaceKey']
connection_string = os.environ['AzureWebJobsStorage']
logAnalyticsUri = os.environ.get('logAnalyticsUri')
baseurl =  os.environ['Baseurl'] 
maxResults = os.environ['MaxResults'] 
Authurl = baseurl+"/apigw/v1/authenticate"
table_name = "LookoutCloudSecurity"
Schedule = os.environ['Schedule']
fetchDelay = os.getenv('FetchDelay',5)
pastDays = os.getenv('PastDays',7)
chunksize = 20000
MaxEventCount = 10000
token = ""
threads,results_events,data = [], [], []


logging.info("The Past days were taken as {}".format(pastDays))
logAnalyticsUri = 'https://' + customer_id + '.ods.opinsights.azure.com'

pattern = r'https:\/\/([\w\-]+)\.ods\.opinsights\.azure.([a-zA-Z\.]+)$'
match = re.match(pattern, str(logAnalyticsUri))
if (not match):
    raise Exception("Lookout: Invalid Log Analytics Uri.")

##############################
######State Manager######  
##############################
class StateManager:
    def __init__(self, connection_string, share_name='funcstatemarkershare', file_path='Anomalyfuncmarkerfile'):
        self.share_cli = ShareClient.from_connection_string(conn_str=connection_string, share_name=share_name)
        self.file_cli = ShareFileClient.from_connection_string(conn_str=connection_string, share_name=share_name, file_path=file_path)

    def post(self, marker_text: str):
        try:
            self.file_cli.upload_file(marker_text)
        except ResourceNotFoundError:
            self.share_cli.create_share()
            self.file_cli.upload_file(marker_text)

    def get(self):
        try:
            return self.file_cli.download_file().readall().decode()
        except ResourceNotFoundError:
            return None
##############################
######lookout Connector######  
##############################

class LookOut:

    def __init__(self):
        self.api_key = jwt_api_key
        self.api_secret = jwt_api_secret
        self.base_url = baseurl
        self.jwt_token_exp_hours = 1
        self.jwt_token = ''#self.get_new_token()          

    def get_new_token(self):
        url = Authurl
        payload = json.dumps({
                "clientId": self.api_key,
                "clientSecret": self.api_secret,
                "grant_type": "refresh_token"
                })
        headers = {
                'Content-Type': 'application/json'
                }
        response = requests.request("POST", url, headers=headers, data=payload)
        tokens = json.loads(response.text)         
        return tokens['id_token']        
	    
    def generate_date(self):
        current_time_day = datetime.utcnow().replace(second=0, microsecond=0) 
        logging.info("Present time {}".format(current_time_day))
        current_time_day = (current_time_day - timedelta(minutes=int(fetchDelay))).strftime("%Y-%m-%dT%H:%M:%S.%fZ")       
        logging.info("the fetch delay taken as {} minutes".format(fetchDelay))
        logging.info("After fetch delay applied time {}".format(current_time_day))
        state = StateManager(connection_string)
        past_time = state.get()
        if past_time is not None:
            logging.info("The last time run happened at: {}".format(past_time))
        else:
            logging.info("There is no last run timestamp, trying to get events for last week.")
            logging.info("The past days were taken as {} days".format(pastDays))
            past_time = (datetime.utcnow().replace(second=0, microsecond=0) - timedelta(days=int(pastDays))).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        return (past_time, current_time_day)

    def get_Data(self,report_type_suffix,startTime,endTime):
            
        try:
            headers = {
                    'Authorization':'Bearer'+' '+ self.jwt_token
                     }
            payload = {}
            logging.info("The url being called: {}".format(baseurl + report_type_suffix+"&startTime="+startTime+"&endTime="+endTime+"&maxResults="+maxResults))
            response = requests.request("GET", baseurl + report_type_suffix+"&startTime="+startTime+"&endTime="+endTime+"&maxResults="+maxResults, headers=headers, data=payload)
            if response.status_code == 200:
                jsondata = json.loads(response.text)
                try:
                  return jsondata['data']
                except KeyError:
                    return []
            elif response.status_code == 400:
                logging.error("The requested report cannot be generated for this account because"
                      " this account has not subscribed to toll-free audio conference plan."
                      " Error code: {}".format(response.status_code))
            elif response.status_code == 401:
                logging.error("Unauthorized. Invalid access token. Error code: {}".format(response.status_code))            
            else:
                logging.error("Something wrong. Error code: {}".format(response.status_code))
        except Exception as err:
            logging.error("Something wrong. Exception error text: {}".format(err))

##############################
######Sentinel Connector######  
##############################

class Sentinel:

    def __init__(self):
        self.logAnalyticsUri = logAnalyticsUri
        self.success_processed = 0
        self.fail_processed = 0
        self.table_name = table_name
        self.chunksize = chunksize 
        self.sharedkey = shared_key

    def gen_chunks(self, data):
        chunks = [data[i:i+chunksize] for i in range(0, len(data), chunksize)]
        logging.info("Entered into the chunks mode")  
        i = 0      
        for chunk in chunks: 
            i = i+1
            logging.debug("Iteration chunk {}".format(i))           
            body = json.dumps(chunk)
            logging.debug(body)
            self.post_data(body, len(chunk))
            state = StateManager(connection_string) 
            latestTimeStamp = chunk[-1]["timeStamp"]
            zulu_time_format = "%Y-%m-%dT%H:%M:%S.%fZ"
            #latestTimeStampnew = datetime.strptime(latestTimeStamp,zulu_time_format) + timedelta(milliseconds=1)
            #logging.info("Chunk Timestamp {}".format(latestTimeStampnew)) 
            #state.post(latestTimeStampnew.strftime("%Y-%m-%dT%H:%M:%S.%fZ"))


    def build_signature(self, date, content_length, method, content_type, resource):
        x_headers = 'x-ms-date:' + date
        string_to_hash = method + "\n" + str(content_length) + "\n" + content_type + "\n" + x_headers + "\n" + resource
        bytes_to_hash = bytes(string_to_hash, encoding="utf-8")
        decoded_key = base64.b64decode(self.sharedkey)
        encoded_hash = base64.b64encode(hmac.new(decoded_key, bytes_to_hash, digestmod=hashlib.sha256).digest()).decode()
        authorization = "SharedKey {}:{}".format(customer_id, encoded_hash)
        return authorization

    def post_data(self, body, chunk_count):
        method = 'POST'
        content_type = 'application/json'
        resource = '/api/logs'
        rfc1123date = datetime.utcnow().strftime('%a, %d %b %Y %H:%M:%S GMT')
        content_length = len(body)
        signature = self.build_signature(rfc1123date, content_length, method, content_type,
                                         resource)
        uri = self.logAnalyticsUri + resource + '?api-version=2016-04-01'
        headers = {
            'content-type': content_type,
            'Authorization': signature,
            'Log-Type': self.table_name,
            'x-ms-date': rfc1123date
        }
        response = requests.post(uri, data=body, headers=headers)
        if (response.status_code >= 200 and response.status_code <= 299):
            logging.info("Chunk was processed{} events".format(chunk_count))
            self.success_processed = self.success_processed + chunk_count
        else:
            logging.error("Error during sending events to Microsoft Sentinel. Response code:{}".format(response.status_code))
            self.fail_processed = self.fail_processed + chunk_count  
def GetAPIData(num):
    try:
        Lookout = LookOut()
        #global results_events
        time.sleep(0.5)
        logging.info("""thread worker function""")
        startTime,endTime = Lookout.generate_date()
        newresults = Lookout.get_Data("/apigw/v1/events?eventType=Anomaly",startTime,endTime)
        #results_events.append([newresults])
        #ProcessToLA(num,newresults)
        return list(newresults)
    except Exception as err:
      logging.error("Something wrong. Exception error text: {}".format(err))
      logging.error( "Error: LookOut Cloud Security events data connector execution failed with an internal server error.")
      raise

def ProcessApiLA(param):
    try:
        startapitime = time.time()
        results = GetAPIData(param)
        logging.info("Api time took to get the {}k events data in {} seconds".format(len(results),time.time() - startapitime))
        apitime = time.time() -startapitime
        startlatime = time.time()
        ProcessToLA(param,results)
        latime = time.time() -startlatime
        logging.info("Data to send it to LA for {}k events took {} seconds".format(len(results),time.time() - startlatime))
        return "function result for thread: {} and it took api time --- {} seconds --- to send --- {} events and it took la time {} and Total time it took to process {}" .format(param,apitime,len(results),latime,apitime + latime)
    except Exception as err:
      logging.error("Something wrong. Exception error text: {}".format(err))
      #logging.error( "Error: LookOut Cloud Security events data connector execution failed with an internal server error.")
      raise

def ProcessToLA(param,results_events):
    start_time = time.time()
    #global results_events
    Lookout = LookOut()
    sentinel = Sentinel()
    logging.info("The number of Anamolies processed {} ".format(len(results_events)))
    logging.info('End: to get Anamolies')
    if(len(results_events)) > 0:
     # Sort the json based on the "timestamp" key
     sorted_data = sorted(results_events, key=lambda x: x["timeStamp"],reverse=False) 
     # Fetch the latest timestamp
     latest_timestamp = sorted_data[-1]["timeStamp"]       
     logging.info("The latest timestamp {}".format(latest_timestamp)) 
     body = json.dumps(results_events)
     if(len(results_events) <= MaxEventCount):
        logging.debug(body)
        sentinel.post_data(body,len(results_events))
        state = StateManager(connection_string) 
        #zulu_time_format = "%Y-%m-%dT%H:%M:%S.%fZ"
        #latestTimeStampnew = datetime.strptime(latest_timestamp,zulu_time_format) + timedelta(milliseconds=1)
        #logging.info("The Final latest Timestamp {}".format(latestTimeStampnew)) 
        #state.post(latestTimeStampnew.strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
     elif(len(results_events) > MaxEventCount):
        sentinel.gen_chunks(sorted_data)
    sentinel_class_vars = vars(sentinel)
    success_processed, fail_processed = sentinel_class_vars["success_processed"],\
                                        sentinel_class_vars["fail_processed"]
    logging.info('Total events processed successfully: {}, failed: {}. Period: {} - {}'
        .format(success_processed, fail_processed, start_time, time.time()))

def ProcessData(param):
    #import concurrent.futures as cf
    start_time = time.time()
    MAX_THREADS = 2
    cpu_num = os.cpu_count()
    #global results_events
    Lookout = LookOut()
    sentinel = Sentinel()
    sentinel.sharedkey = shared_key
    sentinel.table_name= table_name
    startTime,endTime = Lookout.generate_date()
    logging.info("The current run Start time {}".format(startTime))
    logging.info("The current run End time {}".format(endTime))
    logging.info('Start: to get Anamolies')
    parameters = range(3)
    apistart = time.time()
    processes = []
    with ThreadPoolExecutor(cpu_num-1) as process_pool_executor:
        futures = [process_pool_executor.submit(ProcessApiLA, param) for x in list(range(1,2))]
        #processes.append(futures)

    #with mp.Pool(cpu_num*2) as pool:
      #futures = [x for x in pool.map(GetAPIData, range(1,4))]
      #print(time.time() - apistart)
        #results_events.append(results)
    #print("Time took to get the 30k events data in %s",time.time() - apistart)
    for future in as_completed(futures):
        processes.append(future.result())
    #for future in as_completed(futures):
        #print(sum(future.result()))
    #for x in range(len(results)):
        #dat = results_events[x]
        #results_events.extend(results[x])
    #newdata = Lookout.get_Data("/apigw/v1/events?eventType=Anomaly",startTime,endTime)
        #logging.info("Threads executed!")
    #print("Main thread name %s",current_thread().name)
    #time.sleep(0.5)
    #"function result for thread: {} and it took --- {} seconds --- to send --- {} events" .format(param,(time.time() - start_time), "30k" if len(futures) == 3 else "<30k")
    return processes
        #logging.info("Threads executed!")
    #print("Main thread name %s",current_thread().name)

# this function app is fired based on the Timer trigger
# it is used to capture all the events from LookOut cloud security API   
def main(mytimer: func.TimerRequest) -> None:
    utc_timestamp = datetime.utcnow().isoformat()
    cpu_num = os.cpu_count()
    print("Number of CPUs available: ",cpu_num)
    logging.info('Python timer trigger function ran at %s', utc_timestamp)
    logging.info('Starting program')
    print("Start")
    processes = []
    try:
        #with ThreadPoolExecutor(max_workers=1) as executor:
            #futures = [executor.submit(ProcessData, x) for x in list(range(100))]
            #processes.append(futures)
        cpu_count = mp.cpu_count() 

        t1 = time.time()
        with ThreadPoolExecutor(max_workers=None) as executor:
            futures = [executor.submit(ProcessData, x) for x in list(range(150))]
            processes.append(futures)

        #pool = Pool(n)
        #with pool as executor:
            #results = executor.map(ProcessData, range(100), chunksize=1)
            #processes.append(results)
            #t2 = time.time()
        #pool.close()
        #pool.join()
        #print(f'Multiprocessing time using map: {t2 - t1}, chunksize: {chunksize}', results[-1])
        for future in processes[0]:
            logging.info(future.result())
            print(future.result())
        print("End")
    except Exception as err:
      logging.error("Something wrong. Exception error text: {}".format(err))
      logging.error( "Error: LookOut Cloud Security events data connector execution failed with an internal server error.")
      raise